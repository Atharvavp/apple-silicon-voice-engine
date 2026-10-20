import AudioCore
import BenchmarkSupport
import Foundation

/// Per-delivery timing handed to the consumer with each chunk (plan D1 `ConsumeContext`).
/// Real stamps come from the run clock; virtual stamps exist only in step mode.
public struct DeliveryContext: Sendable, Equatable {
    public let plannedDeadlineNS: Int64?
    public let offerNS: Int64
    public let entryNS: Int64
    public let dequeueNS: Int64
    public let mediaDeadlineVirtualNS: Int64?
    public let deliveredVirtualNS: Int64?
    /// Queue depth right after this chunk was dequeued.
    public let queueDepthAfterDequeue: Int
}

/// Producer-side hook (M4): called once per chunk, right after the queue
/// decided on it (accepted or dropped) and, in step mode, before the consumer
/// runs. Dropped chunks never reach the consumer, so loss and backpressure are
/// observable only here. Errors abort the replay like consumer errors.
public protocol ReplayObserver: Sendable {
    func offered(_ chunk: AudioChunk, record: ChunkRecord) async throws
}

public struct ReplayConfiguration: Sendable {
    public let mode: ReplayMode
    public let frameSamples: Int64
    public let speed: ReplaySpeed?
    public let queueCapacity: Int
    public let overflow: OverflowPolicy
    public let identity: FrameIterator.ChunkIdentity

    public init(mode: ReplayMode, frameSamples: Int64, speed: ReplaySpeed?, queueCapacity: Int,
                overflow: OverflowPolicy, runID: String, streamID: String = "audio-0", sourceID: String) throws {
        switch (mode, speed) {
        case (.accelerated, nil): throw ValidationError("speed", "accelerated replay requires a speed")
        case (.realtime, .some), (.step, .some): throw ValidationError("speed", "speed must be nil for \(mode.rawValue)")
        default: break
        }
        guard ConfigLimits.queueCapacity.contains(Int64(queueCapacity)) else {
            throw ValidationError("queue_capacity", "must be in 1...4096")
        }
        self.mode = mode
        self.frameSamples = frameSamples
        self.speed = speed
        self.queueCapacity = queueCapacity
        self.overflow = overflow
        identity = FrameIterator.ChunkIdentity(runID: runID, streamID: streamID, sourceID: sourceID, mode: mode)
    }
}

/// Paces a prepared spool into a bounded queue and drives one consumer (plan C2).
///
/// - realtime / accelerated: one producer task sleeps to absolute deadlines
///   `anchor + offset(end_sample)` on the run clock and offers each chunk; one
///   consumer task receives in FIFO order. A blocked offer keeps its original
///   deadline; deadlines are never reset to "now", never rushed, never skipped.
/// - step: a single coordinator advances virtual time to the chunk's media
///   deadline, admits the chunk, dequeues it and awaits the consumer before the
///   next chunk (acknowledgment barrier). Nothing sleeps; virtual time is not latency.
public enum ReplayScheduler {
    public typealias Consumer = @Sendable (AudioChunk, DeliveryContext) async throws -> Void

    private struct Offered: Sendable {
        let chunk: AudioChunk
        let plannedNS: Int64
        let offerNS: Int64
    }

    private struct Consumed: Sendable {
        let index: Int64
        let dequeueNS: Int64
        let finishNS: Int64
    }

    private enum SideResult: Sendable {
        case producer([ChunkRecord])
        case consumer([Consumed])
    }

    public static func run(spool: PCMSpool, configuration: ReplayConfiguration, clock: any RunClock,
                           virtualClock: VirtualClock = VirtualClock(), observer: (any ReplayObserver)? = nil,
                           consumer: @escaping Consumer) async throws -> ReplayTrace {
        switch configuration.mode {
        case .step:
            return try await runStep(spool: spool, configuration: configuration, clock: clock,
                                     virtualClock: virtualClock, observer: observer, consumer: consumer)
        case .realtime, .accelerated:
            return try await runPaced(spool: spool, configuration: configuration, clock: clock, observer: observer,
                                      consumer: consumer)
        }
    }

    /// Run-clock offset of a chunk's deadline from the replay anchor.
    public static func plannedOffsetNS(endSample: Int64, sampleRateHz: Int64, mode: ReplayMode,
                                       speed: ReplaySpeed?) throws -> Int64 {
        switch mode {
        case .accelerated:
            guard let speed else { throw ValidationError("speed", "accelerated replay requires a speed") }
            return try SampleClock.acceleratedOffsetNS(endSample: endSample, sampleRateHz: sampleRateHz, speed: speed)
        case .realtime, .step:
            return try SampleClock.mediaDeadlineNS(endSample: endSample, sampleRateHz: sampleRateHz)
        }
    }

    private static func runPaced(spool: PCMSpool, configuration: ReplayConfiguration, clock: any RunClock,
                                 observer: (any ReplayObserver)?, consumer: @escaping Consumer) async throws -> ReplayTrace {
        let queue = BoundedQueue<Offered>(capacity: configuration.queueCapacity, policy: configuration.overflow, clock: clock)
        let anchor = clock.nowNS()
        var produced: [ChunkRecord] = []
        var consumed: [Consumed] = []
        do {
            try await withThrowingTaskGroup(of: SideResult.self) { group in
                group.addTask {
                    var records: [ChunkRecord] = []
                    var frames = try FrameIterator(spool: spool, frameSamples: configuration.frameSamples,
                                                   identity: configuration.identity)
                    while let chunk = try frames.nextChunk() {
                        let planned = try CheckedMath.add(anchor, try plannedOffsetNS(
                            endSample: chunk.endSample, sampleRateHz: chunk.sampleRateHz, mode: configuration.mode,
                            speed: configuration.speed))
                        try await clock.sleep(untilNS: planned)
                        let offer = clock.nowNS()
                        let admission = try await queue.send(Offered(chunk: chunk, plannedNS: planned, offerNS: offer))
                        let chunkRecord = record(chunk, planned: planned, virtualDeadline: nil, offer: offer,
                                                 admission: admission, deliveredVirtual: nil)
                        records.append(chunkRecord)
                        try await observer?.offered(chunk, record: chunkRecord)
                    }
                    try frames.verifyAgainstSpool()
                    await queue.close()
                    return .producer(records)
                }
                group.addTask {
                    var finished: [Consumed] = []
                    while let delivery = try await queue.receive() {
                        let offered = delivery.element
                        let context = DeliveryContext(plannedDeadlineNS: offered.plannedNS, offerNS: offered.offerNS,
                                                      entryNS: delivery.entryNS, dequeueNS: delivery.dequeueNS,
                                                      mediaDeadlineVirtualNS: nil, deliveredVirtualNS: nil,
                                                      queueDepthAfterDequeue: delivery.depthAfter)
                        try await consumer(offered.chunk, context)
                        finished.append(Consumed(index: offered.chunk.chunkIndex, dequeueNS: delivery.dequeueNS,
                                                 finishNS: clock.nowNS()))
                    }
                    return .consumer(finished)
                }
                for try await side in group {
                    switch side {
                    case .producer(let records): produced = records
                    case .consumer(let records): consumed = records
                    }
                }
            }
        } catch {
            // Wake whichever side is still suspended so the group can unwind.
            await queue.fail(String(describing: error))
            throw error
        }
        let elapsed = clock.nowNS() - anchor
        return try assemble(produced: produced, consumed: consumed, spool: spool, configuration: configuration,
                            anchor: anchor, elapsed: elapsed, maxDepth: await queue.maxDepth)
    }

    private static func runStep(spool: PCMSpool, configuration: ReplayConfiguration, clock: any RunClock,
                                virtualClock: VirtualClock, observer: (any ReplayObserver)?,
                                consumer: @escaping Consumer) async throws -> ReplayTrace {
        let queue = BoundedQueue<AudioChunk>(capacity: configuration.queueCapacity, policy: configuration.overflow,
                                             clock: clock)
        let anchor = clock.nowNS()
        var frames = try FrameIterator(spool: spool, frameSamples: configuration.frameSamples,
                                       identity: configuration.identity)
        var records: [ChunkRecord] = []
        var consumed: [Consumed] = []
        while let chunk = try frames.nextChunk() {
            let virtualDeadline = try SampleClock.mediaDeadlineNS(endSample: chunk.endSample,
                                                                  sampleRateHz: chunk.sampleRateHz)
            await virtualClock.advance(to: virtualDeadline)
            let offer = clock.nowNS()
            let admission = try await queue.send(chunk)
            let deliveredVirtual = await virtualClock.nowNS
            guard case .accepted = admission, let delivery = try await queue.receive() else {
                // The barrier keeps depth at most one, so admission into an empty queue cannot fail.
                throw CoverageError(message: "step replay could not admit chunk \(chunk.chunkIndex)")
            }
            let context = DeliveryContext(plannedDeadlineNS: nil, offerNS: offer, entryNS: delivery.entryNS,
                                          dequeueNS: delivery.dequeueNS, mediaDeadlineVirtualNS: virtualDeadline,
                                          deliveredVirtualNS: deliveredVirtual, queueDepthAfterDequeue: delivery.depthAfter)
            let chunkRecord = record(chunk, planned: nil, virtualDeadline: virtualDeadline, offer: offer,
                                     admission: admission, deliveredVirtual: deliveredVirtual)
            // Acknowledgment barrier: scheduled/delivered are recorded before any adapter output.
            try await observer?.offered(chunk, record: chunkRecord)
            try await consumer(chunk, context)
            records.append(chunkRecord)
            consumed.append(Consumed(index: chunk.chunkIndex, dequeueNS: delivery.dequeueNS, finishNS: clock.nowNS()))
        }
        try frames.verifyAgainstSpool()
        await queue.close()
        return try assemble(produced: records, consumed: consumed, spool: spool, configuration: configuration,
                            anchor: anchor, elapsed: clock.nowNS() - anchor, maxDepth: await queue.maxDepth)
    }

    private static func record(_ chunk: AudioChunk, planned: Int64?, virtualDeadline: Int64?, offer: Int64,
                               admission: BoundedQueue<some Sendable>.Admission, deliveredVirtual: Int64?) -> ChunkRecord {
        switch admission {
        case let .accepted(entryNS, depthAfter, blocked):
            return ChunkRecord(index: chunk.chunkIndex, startSample: chunk.startSample, endSample: chunk.endSample,
                               plannedDeadlineNS: planned, virtualDeadlineNS: virtualDeadline, offerNS: offer,
                               outcome: .accepted, entryNS: entryNS, blocked: blocked, depthAfterEntry: depthAfter,
                               dequeueNS: nil, finishNS: nil, deliveredVirtualNS: deliveredVirtual)
        case .dropped:
            return ChunkRecord(index: chunk.chunkIndex, startSample: chunk.startSample, endSample: chunk.endSample,
                               plannedDeadlineNS: planned, virtualDeadlineNS: virtualDeadline, offerNS: offer,
                               outcome: .dropped, entryNS: nil, blocked: false, depthAfterEntry: nil,
                               dequeueNS: nil, finishNS: nil, deliveredVirtualNS: deliveredVirtual)
        }
    }

    private static func assemble(produced: [ChunkRecord], consumed: [Consumed], spool: PCMSpool,
                                 configuration: ReplayConfiguration, anchor: Int64, elapsed: Int64,
                                 maxDepth: Int) throws -> ReplayTrace {
        var records = produced
        var position: [Int64: Int] = [:]
        for (offset, record) in records.enumerated() { position[record.index] = offset }
        for item in consumed {
            guard let offset = position[item.index] else {
                throw CoverageError(message: "consumer finished unknown chunk \(item.index)")
            }
            records[offset].dequeueNS = item.dequeueNS
            records[offset].finishNS = item.finishNS
        }
        return ReplayTrace(mode: configuration.mode, sampleRateHz: spool.sampleRateHz,
                           frameSamples: configuration.frameSamples, speed: configuration.speed,
                           totalFrames: spool.frameCount, overflow: configuration.overflow,
                           queueCapacity: configuration.queueCapacity, anchorNS: anchor, elapsedNS: elapsed,
                           records: records, consumptionOrder: consumed.map(\.index), maxQueueDepth: maxDepth)
    }
}
