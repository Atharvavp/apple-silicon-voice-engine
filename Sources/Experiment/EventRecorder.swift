import AdapterContracts
import BenchmarkSupport
import Foundation
import Replay

/// A record waiting for admission. `build` receives the global sequence and
/// the recorder admission instant (both assigned by the recorder) and returns
/// the encoded line without its newline.
public struct PendingLine: Sendable {
    public let build: @Sendable (_ sequence: Int64, _ recordedNS: Int64) throws -> Data

    public init(_ build: @escaping @Sendable (_ sequence: Int64, _ recordedNS: Int64) throws -> Data) {
        self.build = build
    }
}

/// Bounded JSONL pipeline (plan C2): producers block when `capacity` lines are
/// waiting (never dropped), one writer task drains in admission (FIFO) order and
/// writes batches through a `SerialFileWriter`. Sequence = dequeue order =
/// admission order; recorded time = the queue's admission stamp, taken before
/// any disk write. A writer failure fails the queue, which wakes every blocked
/// producer with an error.
public actor JSONLStream {
    public nonisolated let writer: SerialFileWriter
    private let queue: BoundedQueue<PendingLine>
    private let maxRecordBytes: Int
    private var writerTask: Task<Int64, Error>?
    private var nextSequence: Int64?
    private var failure: Error?

    public init(url: URL, capacity: Int, maxRecordBytes: Int, maxBytes: Int64, clock: any RunClock) throws {
        writer = try SerialFileWriter(url: url, maxBytes: maxBytes, clock: clock)
        queue = BoundedQueue(capacity: capacity, policy: .block, clock: clock)
        self.maxRecordBytes = maxRecordBytes
    }

    public func start() {
        guard writerTask == nil else { return }
        let queue = self.queue
        let writer = self.writer
        let limit = maxRecordBytes
        writerTask = Task {
            var sequence: Int64 = 0
            do {
                while let first = try await queue.receive() {
                    let batch = [first] + (try await queue.receiveAvailable(limit: 255))
                    var data = Data()
                    for delivery in batch {
                        let line = try delivery.element.build(sequence, delivery.entryNS)
                        guard line.count <= limit else {
                            throw RecorderError("record \(sequence) is \(line.count) bytes; the limit is \(limit)")
                        }
                        data.append(line)
                        data.append(0x0A)
                        sequence += 1
                    }
                    try await writer.append(data, lines: batch.count)
                }
                return sequence
            } catch {
                await queue.fail("recorder writer failed: \(error)")
                throw error
            }
        }
    }

    /// Bounded admission; suspends while the queue is full.
    public nonisolated func admit(_ line: PendingLine) async throws {
        do {
            _ = try await queue.send(line)
        } catch let error as QueueError {
            switch error {
            case .closed: throw RecorderError("record offered after the stream was frozen")
            case .failed(let reason): throw RecorderError(reason)
            }
        }
    }

    /// Stops admission, drains every admitted line to disk, fsyncs, and returns
    /// the next free sequence number.
    public func drainAndSync() async throws -> Int64 {
        if let nextSequence { return nextSequence }
        await queue.close()
        guard let writerTask else { throw RecorderError("stream was never started") }
        let next = try await writerTask.value
        try await writer.synchronize()
        nextSequence = next
        return next
    }

    /// Fails the stream after a run failure, waking any blocked producer.
    public func abandon() async {
        await queue.fail("stream abandoned after a run failure")
    }

    public var maxDepth: Int {
        get async { await queue.maxDepth }
    }
}

/// The event trace (`events.jsonl.partial` -> `events.jsonl`).
///
/// States: open (bounded admission) -> runtime-frozen (prefix fixed; exactly
/// one terminal event may follow) -> finalized. The runtime prefix descriptor
/// identifies the bytes predictions and metrics were computed from; appending
/// the terminal event never changes them.
public actor EventRecorder {
    public static let partialName = "events.jsonl.partial"
    public static let finalName = "events.jsonl"

    public nonisolated let stream: JSONLStream
    private let directory: RunDirectory
    private let clock: any RunClock
    private var prefix: PrefixDescriptor?
    private var terminalWritten = false
    private var nextSequence: Int64?

    public struct PrefixDescriptor: Sendable, Equatable, JSONRepresentable {
        public let path: String
        public let byteCount: Int64
        public let lineCount: Int64
        public let sha256: String

        public func toJSON() -> JSONValue {
            .object(JSONObject([("path", .string(path)), ("byte_count", .int(byteCount)),
                                ("line_count", .int(lineCount)), ("sha256", .string(sha256))]))
        }
    }

    public init(directory: RunDirectory, clock: any RunClock, capacity: Int = 256, maxRecordBytes: Int = 1 << 20,
                maxBytes: Int64) throws {
        self.directory = directory
        self.clock = clock
        stream = try JSONLStream(url: directory.path(Self.partialName), capacity: capacity,
                                 maxRecordBytes: maxRecordBytes, maxBytes: maxBytes, clock: clock)
    }

    public func start() async { await stream.start() }

    /// Freezes the runtime prefix: no ordinary event is admitted afterwards.
    public func freezeRuntimePrefix() async throws -> PrefixDescriptor {
        if let prefix { return prefix }
        let next = try await stream.drainAndSync()
        let stats = try await stream.writer.snapshot()
        let descriptor = PrefixDescriptor(path: Self.finalName, byteCount: stats.bytes, lineCount: stats.lines,
                                          sha256: stats.sha256)
        guard stats.lines == next else {
            throw RecorderError("prefix has \(stats.lines) lines but \(next) sequences were assigned")
        }
        prefix = descriptor
        nextSequence = next
        return descriptor
    }

    /// Appends the single terminal event at the next sequence. Before a runtime
    /// freeze (failure paths) it first drains whatever was admitted.
    @discardableResult
    public func appendTerminal(_ make: @Sendable (_ sequence: Int64, _ nowNS: Int64) throws -> EventEnvelope) async throws -> EventEnvelope {
        guard !terminalWritten else { throw RecorderError("a terminal event was already written") }
        let sequence: Int64
        if let nextSequence { sequence = nextSequence } else { sequence = try await stream.drainAndSync() }
        let envelope = try make(sequence, clock.nowNS())
        try envelope.validate()
        guard envelope.type.isTerminal, envelope.sequence == sequence else {
            throw RecorderError("terminal append needs a terminal event at sequence \(sequence)")
        }
        var data = try JSONWriter.compact(envelope.toJSON())
        data.append(0x0A)
        try await stream.writer.append(data, lines: 1)
        terminalWritten = true
        nextSequence = sequence + 1
        return envelope
    }

    /// Closes the file; on success renames `.partial` to the final name.
    public func finalize(success: Bool) async throws -> ArtifactDigest {
        try await stream.writer.close()
        var name = Self.partialName
        if success {
            guard terminalWritten else { throw RecorderError("cannot finalize a trace without its terminal event") }
            guard renamex_np(directory.path(Self.partialName).path, directory.path(Self.finalName).path,
                             UInt32(RENAME_EXCL)) == 0 else {
                throw RecorderError("cannot rename trace: \(String(cString: strerror(errno)))")
            }
            name = Self.finalName
        }
        return try directory.digest(name)
    }

    public var lastSequence: Int64? { nextSequence.map { $0 - 1 } }
    public var hasTerminal: Bool { terminalWritten }
    public var frozenPrefix: PrefixDescriptor? { prefix }
}

/// Emits events for one producer. Producer sequence and the per-type logical
/// ordinal (used in the stable event ID) are assigned before any suspension, so
/// they are deterministic whenever the producer's calls are.
public actor ProducerChannel {
    public let producerID: String
    private let identity: RunIdentity
    private let stream: JSONLStream
    private var producerSequence: Int64 = 0
    private var ordinals: [EventType: Int64] = [:]

    public init(producerID: String, identity: RunIdentity, stream: JSONLStream) {
        self.producerID = producerID
        self.identity = identity
        self.stream = stream
    }

    public func emit(_ type: EventType, media: SampleInterval? = nil, causeChunk: Int64? = nil, invocation: String? = nil,
                     payload: JSONObject, emittedNS: Int64, virtualNS: Int64? = nil) async throws {
        let ordinal = ordinals[type, default: 0]
        ordinals[type] = ordinal + 1
        let producerSequence = self.producerSequence
        self.producerSequence += 1
        let draft = EventEnvelope(
            eventID: "\(identity.sourceID)/\(producerID)/\(type.rawValue)/\(ordinal)", runID: identity.runID,
            streamID: identity.streamID, sourceID: identity.sourceID, sequence: 0, producerID: producerID,
            producerSequence: producerSequence, type: type, mediaStartSample: media?.start, mediaEndSample: media?.end,
            sampleRateHz: identity.sampleRateHz, monotonicEmittedNS: emittedNS, monotonicRecordedNS: emittedNS,
            virtualEmittedNS: virtualNS, causeChunkIndex: causeChunk, invocationID: invocation, payload: payload)
        // Validate before admission so a malformed event fails at its producer.
        do { try draft.validate() } catch {
            throw RecorderError("invalid \(type.rawValue) event from \(producerID): \(error)")
        }
        try await stream.admit(PendingLine { sequence, recordedNS in
            var envelope = draft
            envelope.sequence = sequence
            envelope.monotonicRecordedNS = recordedNS
            return try JSONWriter.compact(envelope.toJSON())
        })
    }
}

/// Run/stream/source identity stamped on every event.
public struct RunIdentity: Sendable, Equatable {
    public let runID: String
    public let streamID: String
    public let sourceID: String
    public let sampleRateHz: Int64

    public init(runID: String, streamID: String = "audio-0", sourceID: String, sampleRateHz: Int64) {
        self.runID = runID
        self.streamID = streamID
        self.sourceID = sourceID
        self.sampleRateHz = sampleRateHz
    }
}
