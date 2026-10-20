import AudioCore
import BenchmarkSupport
import Foundation

/// Streaming adapter contract (plan D1). ASR and diarization adapters conform
/// separately; the shared shape does not imply joint inference or word
/// attribution.
///
/// Call order, enforced by the runner and checked by `AdapterLifecycle`:
/// `prepare` once, `consume` zero or more times in chunk order, `flush` once
/// at end of stream (it must not return until every output of the adapter has
/// been emitted through the sink), then `shutdown`, which is idempotent, is
/// called exactly once by the runner (also after a failed `prepare`) and must
/// leave no unjoined work. Outputs go only through the sink passed to
/// `prepare`; an adapter never writes artifacts or chooses event sequences.
public protocol StreamingAdapter: Sendable {
    var adapterID: String { get }
    var role: AdapterRole { get }
    func prepare(context: AdapterContext, sink: any AdapterEventSink) async throws -> AdapterCapabilities
    func consume(_ chunk: AudioChunk, context: ConsumeContext) async throws
    func flush(endOfStream: StreamEnd) async throws
    func shutdown() async -> AdapterShutdownReport
}

public protocol ASRAdapter: StreamingAdapter {}
public protocol DiarizationAdapter: StreamingAdapter {}

/// Receives adapter output. Admission is bounded: `emit` may suspend while the
/// recorder catches up, and it throws when the event violates the output
/// contract or the recorder has failed. Errors must propagate to the caller.
public protocol AdapterEventSink: Sendable {
    func emit(_ event: AdapterEvent) async throws
}

/// Models adapter processing time. Step mode advances the virtual clock without
/// sleeping; realtime/accelerated modes sleep on the run clock. Either way the
/// adapter just calls `delay`.
public protocol AdapterDelayService: Sendable {
    func delay(milliseconds: Int64) async throws
}

/// Typed adapter failure (plan D1 error shape: category/stage/adapter/chunk/message).
public struct AdapterError: Error, Equatable, CustomStringConvertible {
    public enum Kind: String, Sendable, CaseIterable {
        /// A call arrived out of the prepare/consume/flush/shutdown order.
        case lifecycle
        /// The stream format or chunking is unacceptable to the adapter.
        case incompatibleInput = "incompatible_input"
        /// An emitted event broke the output contract (range, revision order, duplicate ID).
        case contract
        /// A mock fixture script is missing, mismatched or malformed.
        case fixture
        /// A failure deliberately declared in a mock fixture script (test-only).
        case injectedFault = "injected_fault"
        /// Any other adapter-internal failure.
        case backend
    }

    public let kind: Kind
    public let adapterID: String
    public let stage: AdapterStage
    public let chunkIndex: Int64?
    public let message: String

    public init(_ kind: Kind, adapterID: String, stage: AdapterStage, chunkIndex: Int64? = nil, _ message: String) {
        self.kind = kind
        self.adapterID = adapterID
        self.stage = stage
        self.chunkIndex = chunkIndex
        self.message = message
    }

    public var description: String {
        let chunk = chunkIndex.map { " chunk \($0)" } ?? ""
        return "adapter \(adapterID) \(stage.rawValue)\(chunk): \(kind.rawValue): \(message)"
    }
}

public enum AdapterStage: String, Sendable, CaseIterable {
    case prepare, consume, flush, shutdown, emit
}

/// Call-order guard shared by adapter implementations.
public struct AdapterLifecycle: Sendable {
    public enum State: String, Sendable { case created, prepared, flushed, shutDown = "shut_down" }

    public private(set) var state: State = .created
    public let adapterID: String

    public init(adapterID: String) { self.adapterID = adapterID }

    public mutating func beginPrepare() throws {
        guard state == .created else { throw violation(.prepare, "prepare called in state \(state.rawValue)") }
        state = .prepared
    }

    public func checkConsume(chunkIndex: Int64) throws {
        guard state == .prepared else {
            throw violation(.consume, "consume called in state \(state.rawValue)", chunk: chunkIndex)
        }
    }

    public mutating func beginFlush() throws {
        guard state == .prepared else { throw violation(.flush, "flush called in state \(state.rawValue)") }
        state = .flushed
    }

    /// Returns true only on the first call; later calls are no-ops (idempotent shutdown).
    public mutating func beginShutdown() -> Bool {
        guard state != .shutDown else { return false }
        state = .shutDown
        return true
    }

    private func violation(_ stage: AdapterStage, _ message: String, chunk: Int64? = nil) -> AdapterError {
        AdapterError(.lifecycle, adapterID: adapterID, stage: stage, chunkIndex: chunk, message)
    }
}
