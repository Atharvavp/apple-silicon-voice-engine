import BenchmarkSupport
import Foundation

/// Adapter-facing PCM format (plan D1). In memory, samples are native `Float`;
/// `float32_le` is the on-disk/transport encoding.
public struct PCMFormat: Sendable, Equatable, JSONRepresentable {
    public let sampleRateHz: Int64
    public let channels: Int64
    public let encoding: String

    public init(sampleRateHz: Int64, channels: Int64 = 1, encoding: String = "float32_le") {
        self.sampleRateHz = sampleRateHz
        self.channels = channels
        self.encoding = encoding
    }

    public func toJSON() -> JSONValue {
        .object(JSONObject([("sample_rate_hz", .int(sampleRateHz)), ("channels", .int(channels)),
                            ("encoding", .string(encoding))]))
    }
}

/// A fixture prediction script declared by the dataset item (mock adapters only).
/// The adapter verifies the hash of the bytes it actually reads.
public struct FixtureScriptReference: Sendable, Equatable {
    public let url: URL
    public let sha256: String

    public init(url: URL, sha256: String) {
        self.url = url
        self.sha256 = sha256
    }
}

/// Everything an adapter receives at `prepare` (plan D1 `AdapterContext`).
public struct AdapterContext: Sendable {
    public let role: AdapterRole
    public let selection: AdapterSelection
    public let runID: String
    public let streamID: String
    public let sourceID: String
    public let format: PCMFormat
    public let durationSamples: Int64
    public let frameSamples: Int64
    public let mode: ReplayMode
    public let seed: Int64
    public let fixtureScript: FixtureScriptReference?
    public let delays: any AdapterDelayService
    /// Real run clock, for adapters that time their own work. Never the virtual clock.
    public let clock: any RunClock

    public init(role: AdapterRole, selection: AdapterSelection, runID: String, streamID: String, sourceID: String,
                format: PCMFormat, durationSamples: Int64, frameSamples: Int64, mode: ReplayMode, seed: Int64,
                fixtureScript: FixtureScriptReference?, delays: any AdapterDelayService, clock: any RunClock) {
        self.role = role
        self.selection = selection
        self.runID = runID
        self.streamID = streamID
        self.sourceID = sourceID
        self.format = format
        self.durationSamples = durationSamples
        self.frameSamples = frameSamples
        self.mode = mode
        self.seed = seed
        self.fixtureScript = fixtureScript
        self.delays = delays
        self.clock = clock
    }
}

/// Per-invocation timing context (plan D1 `ConsumeContext`). Real stamps are
/// run-clock nanoseconds; virtual stamps exist only in step mode. The chunk
/// itself carries no timing; the two join by `(run_id, stream_id, chunk_index)`.
public struct ConsumeContext: Sendable, Equatable {
    public let invocationID: String
    /// Planned real deadline; nil in step mode.
    public let scheduledMonotonicNS: Int64?
    /// Queue admission instant.
    public let deliveredMonotonicNS: Int64
    /// Dequeue instant.
    public let queueExitMonotonicNS: Int64
    public let mediaDeadlineVirtualNS: Int64?
    public let deliveredVirtualNS: Int64?

    public init(invocationID: String, scheduledMonotonicNS: Int64?, deliveredMonotonicNS: Int64,
                queueExitMonotonicNS: Int64, mediaDeadlineVirtualNS: Int64?, deliveredVirtualNS: Int64?) {
        self.invocationID = invocationID
        self.scheduledMonotonicNS = scheduledMonotonicNS
        self.deliveredMonotonicNS = deliveredMonotonicNS
        self.queueExitMonotonicNS = queueExitMonotonicNS
        self.mediaDeadlineVirtualNS = mediaDeadlineVirtualNS
        self.deliveredVirtualNS = deliveredVirtualNS
    }
}

/// End-of-stream facts handed to `flush` (plan D1 `StreamEnd`).
public struct StreamEnd: Sendable, Equatable {
    public enum Reason: String, Sendable { case normal, cancelled }

    public let invocationID: String
    /// Total frames of the converted stream (`[0, finalSample)`).
    public let finalSample: Int64
    public let consumedSamples: Int64
    /// Pipeline-level losses, shared by both adapters (never double-counted).
    public let droppedRanges: [SampleInterval]
    public let reason: Reason

    public init(invocationID: String, finalSample: Int64, consumedSamples: Int64, droppedRanges: [SampleInterval],
                reason: Reason) {
        self.invocationID = invocationID
        self.finalSample = finalSample
        self.consumedSamples = consumedSamples
        self.droppedRanges = droppedRanges
        self.reason = reason
    }
}
