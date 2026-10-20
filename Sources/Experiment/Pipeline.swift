import AdapterContracts
import AudioCore
import BenchmarkSupport
import Foundation
import MockAdapters
import Replay

extension AdapterFactory {
    /// The adapters shipped with Phase 0: deterministic mocks only.
    public static let builtIn = AdapterFactory(entries: [
        MockAdapterIDs.asr: Entry(role: .asr, requestedPlacement: .cpu, isMock: true) { MockASRAdapter() },
        MockAdapterIDs.diarization: Entry(role: .diarization, requestedPlacement: .cpu, isMock: true) {
            MockDiarizationAdapter()
        },
    ])
}

/// Step mode: a mock delay advances the shared virtual clock; nothing sleeps.
struct VirtualClockDelays: AdapterDelayService {
    let virtualClock: VirtualClock
    func delay(milliseconds: Int64) async throws {
        await virtualClock.advance(byNS: milliseconds * 1_000_000)
    }
}

/// Realtime/accelerated: a mock delay sleeps to an absolute run-clock deadline.
struct RunClockDelays: AdapterDelayService {
    let clock: any RunClock
    func delay(milliseconds: Int64) async throws {
        try await clock.sleep(untilNS: try CheckedMath.add(clock.nowNS(), milliseconds * 1_000_000))
    }
}

/// Production sink for one adapter (plan D1/D5): stamps the emission time at
/// entry, applies the output contract, adds identity, and admits the event
/// through the bounded recorder. Adapters never choose sequences or timestamps.
actor RecordingAdapterSink: AdapterEventSink {
    private let channel: ProducerChannel
    private let role: AdapterRole
    private let adapterID: String
    private let clock: any RunClock
    private let virtualClock: VirtualClock?
    private var validator: AdapterOutputValidator

    init(channel: ProducerChannel, role: AdapterRole, adapterID: String, durationSamples: Int64,
         clock: any RunClock, virtualClock: VirtualClock?) {
        self.channel = channel
        self.role = role
        self.adapterID = adapterID
        self.clock = clock
        self.virtualClock = virtualClock
        validator = AdapterOutputValidator(role: role, adapterID: adapterID, durationSamples: durationSamples,
                                           transcriptGranularity: role == .asr ? .utterances : nil)
    }

    /// Re-arms the validator with the granularity the adapter actually declared.
    func configure(capabilities: AdapterCapabilities, durationSamples: Int64) {
        validator = AdapterOutputValidator(role: role, adapterID: adapterID, durationSamples: durationSamples,
                                           transcriptGranularity: capabilities.transcriptGranularity)
    }

    func emit(_ event: AdapterEvent) async throws {
        let emitted = clock.nowNS()
        try validator.check(event)
        let virtual = await virtualClock?.nowNS
        try await channel.emit(event.eventType, media: event.media, causeChunk: event.cause.chunkIndex,
                               invocation: event.cause.invocationID,
                               payload: event.payload(role: role, adapterID: adapterID), emittedNS: emitted,
                               virtualNS: virtual)
    }

    var unfinalizedUtterances: [String] { validator.unfinalizedUtterances }
}

/// Records `audio.chunk_scheduled`/`delivered`/`queue_backpressure`/`queue_overflow`
/// from the replay producer, where they actually happen (plan D5).
final class ReplayEventObserver: ReplayObserver {
    private let channel: ProducerChannel
    private let clock: any RunClock
    private let virtualClock: VirtualClock?
    private let capacity: Int64
    private let lost = LostCounter()

    actor LostCounter {
        var total: Int64 = 0
        func add(_ count: Int64) -> Int64 {
            total += count
            return total
        }
    }

    init(channel: ProducerChannel, clock: any RunClock, virtualClock: VirtualClock?, capacity: Int) {
        self.channel = channel
        self.clock = clock
        self.virtualClock = virtualClock
        self.capacity = Int64(capacity)
    }

    func offered(_ chunk: AudioChunk, record: ChunkRecord) async throws {
        let range = try SampleInterval(start: record.startSample, end: record.endSample)
        let virtual = await virtualClock?.nowNS
        try await channel.emit(.audioChunkScheduled, media: range, causeChunk: record.index, payload: JSONObject([
            ("chunk_index", .int(record.index)), ("start_sample", .int(record.startSample)),
            ("end_sample", .int(record.endSample)), ("deadline_convention", .string(SampleClock.deadlineConvention)),
            ("planned_deadline_ns", record.plannedDeadlineNS.json),
            ("media_deadline_virtual_ns", record.virtualDeadlineNS.json),
        ]), emittedNS: clock.nowNS(), virtualNS: virtual)
        switch record.outcome {
        case .accepted:
            guard let entry = record.entryNS else { throw CoverageError(message: "accepted chunk \(record.index) has no entry stamp") }
            try await channel.emit(.audioChunkDelivered, causeChunk: record.index, payload: JSONObject([
                ("chunk_index", .int(record.index)), ("offer_ns", .int(record.offerNS)), ("entry_ns", .int(entry)),
                ("wake_error_ns", record.wakeErrorNS.json), ("deadline_error_ns", record.deliveryErrorNS.json),
                ("queue_depth", .int(Int64(record.depthAfterEntry ?? 0))),
                ("delivered_virtual_ns", record.deliveredVirtualNS.json),
            ]), emittedNS: clock.nowNS(), virtualNS: virtual)
            if record.blocked {
                try await channel.emit(.audioQueueBackpressure, causeChunk: record.index, payload: JSONObject([
                    ("chunk_index", .int(record.index)), ("blocked_ns", .int(entry - record.offerNS)),
                    ("capacity", .int(capacity)), ("policy", .string(OverflowPolicy.block.rawValue)),
                ]), emittedNS: clock.nowNS(), virtualNS: virtual)
            }
        case .dropped:
            let cumulative = await lost.add(record.sampleCount)
            try await channel.emit(.audioQueueOverflow, media: range, causeChunk: record.index, payload: JSONObject([
                ("chunk_index", .int(record.index)), ("policy", .string(OverflowPolicy.dropNewest.rawValue)),
                ("start_sample", .int(record.startSample)), ("end_sample", .int(record.endSample)),
                ("lost_samples", .int(record.sampleCount)), ("cumulative_lost_samples", .int(cumulative)),
            ]), emittedNS: clock.nowNS(), virtualNS: virtual)
        }
    }
}

/// One pipeline worker (plan C2): for each accepted chunk, ASR.consume then
/// diarization.consume in a fixed order, one `stage.completed` per invocation
/// (real duration, plus virtual duration in step mode), then `audio.chunk_consumed`.
struct PipelineWorker: Sendable {
    let adapters: [any StreamingAdapter]
    let channel: ProducerChannel
    let adapterChannels: [String: ProducerChannel]
    let clock: any RunClock
    let virtualClock: VirtualClock?

    func consume(_ chunk: AudioChunk, _ delivery: DeliveryContext) async throws {
        var invocations: [String] = []
        for adapter in adapters {
            let invocation = "\(adapter.role.rawValue)/consume/\(chunk.chunkIndex)"
            invocations.append(invocation)
            let context = ConsumeContext(invocationID: invocation, scheduledMonotonicNS: delivery.plannedDeadlineNS,
                                         deliveredMonotonicNS: delivery.entryNS, queueExitMonotonicNS: delivery.dequeueNS,
                                         mediaDeadlineVirtualNS: delivery.mediaDeadlineVirtualNS,
                                         deliveredVirtualNS: delivery.deliveredVirtualNS)
            let virtualStart = await virtualClock?.nowNS
            let start = clock.nowNS()
            do {
                try await adapter.consume(chunk, context: context)
            } catch {
                await reportFailure(adapter, stage: "consume", error)
                throw error
            }
            let end = clock.nowNS()
            let virtualEnd = await virtualClock?.nowNS
            try await stage("\(adapter.role.rawValue).consume", start: start, end: end,
                            virtual: virtualStart.flatMap { s in virtualEnd.map { $0 - s } },
                            invocation: invocation, chunk: chunk.chunkIndex, virtualNow: virtualEnd)
        }
        let finish = clock.nowNS()
        try await channel.emit(.audioChunkConsumed, media: try SampleInterval(start: chunk.startSample, end: chunk.endSample),
                               causeChunk: chunk.chunkIndex, payload: JSONObject([
            ("chunk_index", .int(chunk.chunkIndex)), ("start_sample", .int(chunk.startSample)),
            ("end_sample", .int(chunk.endSample)), ("dequeue_ns", .int(delivery.dequeueNS)), ("finish_ns", .int(finish)),
            ("invocation_ids", .array(invocations.map(JSONValue.string))),
            ("queue_depth", .int(Int64(delivery.queueDepthAfterDequeue))),
        ]), emittedNS: finish, virtualNS: await virtualClock?.nowNS)
    }

    func stage(_ name: String, start: Int64, end: Int64, virtual: Int64?, invocation: String?, chunk: Int64?,
               virtualNow: Int64?) async throws {
        try await channel.emit(.stageCompleted, causeChunk: chunk, invocation: invocation, payload: JSONObject([
            ("stage", .string(name)), ("start_ns", .int(start)), ("end_ns", .int(end)), ("duration_ns", .int(end - start)),
            ("virtual_duration_ns", virtual.json),
        ]), emittedNS: clock.nowNS(), virtualNS: virtualNow)
    }

    /// Best-effort `adapter.failed`; the primary error is rethrown by the caller.
    func reportFailure(_ adapter: any StreamingAdapter, stage: String, _ error: Error) async {
        guard let adapterChannel = adapterChannels[adapter.adapterID] else { return }
        try? await adapterChannel.emit(.adapterFailed, payload: JSONObject([
            ("role", .string(adapter.role.rawValue)), ("adapter_id", .string(adapter.adapterID)),
            ("stage", .string(stage)), ("message", .string(String(describing: error))),
        ]), emittedNS: clock.nowNS(), virtualNS: await virtualClock?.nowNS)
    }
}
