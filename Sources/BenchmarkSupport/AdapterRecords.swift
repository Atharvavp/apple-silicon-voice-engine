import Foundation

/// Adapter role. ASR and diarization are separate contracts; one adapter never
/// advertises both roles (plan D1).
public enum AdapterRole: String, Sendable, CaseIterable {
    case asr, diarization
}

/// Requested execution placement (plan D6). A request is not an observation.
public enum PlacementTarget: String, Sendable, CaseIterable {
    case cpu, gpu, ane, unspecified
}

/// Granularity of the transcript an ASR adapter emits. `recording` output is
/// untimed: its transcript events carry no media range and cannot feed
/// media-linked latency metrics.
public enum TranscriptOutputGranularity: String, Sendable, CaseIterable {
    case utterances, words, recording
}

/// A fact that may be unavailable: `{status, value, source, reason}` (environment
/// hardware, telemetry capabilities, observed placement). `ok` needs a value and
/// no reason; every other status needs a null value and a reason. Never a guess.
public struct FactObservation: Sendable, Equatable, JSONRepresentable {
    public let status: MetricStatus
    public let value: JSONValue
    public let source: String
    public let reason: String?

    public init(status: MetricStatus, value: JSONValue, source: String, reason: String?, path: String = "$") throws {
        self.status = status
        self.value = value
        self.source = source
        self.reason = reason
        try validate(path)
    }

    public static func ok(_ value: JSONValue, source: String) -> FactObservation {
        // Force-try is safe: an ok fact with a non-null scalar is always valid.
        try! FactObservation(status: .ok, value: value, source: source, reason: nil)
    }

    public static func missing(_ status: MetricStatus, source: String, reason: String) -> FactObservation {
        precondition(status != .ok && !reason.isEmpty)
        return try! FactObservation(status: status, value: .null, source: source, reason: reason)
    }

    func validate(_ path: String) throws {
        guard !source.isEmpty else { throw ValidationError("\(path).source", "must be a non-empty string") }
        switch value {
        case .null, .string, .int, .double, .bool: break
        default: throw ValidationError("\(path).value", "must be a scalar or null")
        }
        if status == .ok {
            guard !value.isNull else { throw ValidationError("\(path).value", "status ok requires a value") }
            guard reason == nil else { throw ValidationError("\(path).reason", "status ok requires a null reason") }
        } else {
            guard value.isNull else { throw ValidationError("\(path).value", "status \(status.rawValue) requires a null value") }
            guard let reason, !reason.isEmpty else {
                throw ValidationError("\(path).reason", "status \(status.rawValue) requires a non-empty reason")
            }
        }
    }

    public static func read(_ value: JSONValue, _ path: String) throws -> FactObservation {
        var r = try FieldReader(value, path: path)
        let fact = try FactObservation(status: try r.enumeration("status", MetricStatus.self), value: try r.raw("value"),
                                       source: try r.nonEmptyString("source"),
                                       reason: try r.nullable("reason", JSONRead.nonEmptyString), path: path)
        try r.finish()
        return fact
    }

    public func toJSON() -> JSONValue {
        .object(JSONObject([("status", .string(status.rawValue)), ("value", value), ("source", .string(source)),
                            ("reason", reason.json)]))
    }
}

/// What an adapter reports from `prepare` (plan D1). The runner checks the
/// input constraints against the prepared audio before replay starts.
public struct AdapterCapabilities: Sendable, Equatable, JSONRepresentable {
    public let role: AdapterRole
    public let revision: String
    /// Sample rates the adapter accepts; the converted stream rate must be one of them.
    public let sampleRatesHz: [Int64]
    /// Channel count the adapter accepts (v1 streams are mono).
    public let channels: Int64
    /// When set, every non-final chunk must be a multiple of this many samples.
    public let frameMultipleSamples: Int64?
    public let incremental: Bool
    public let emitsPartials: Bool
    public let emitsFinals: Bool
    /// ASR only; nil for diarization.
    public let transcriptGranularity: TranscriptOutputGranularity?
    public let requestedPlacement: PlacementTarget
    public let observedPlacement: FactObservation

    public init(role: AdapterRole, revision: String, sampleRatesHz: [Int64], channels: Int64,
                frameMultipleSamples: Int64?, incremental: Bool, emitsPartials: Bool, emitsFinals: Bool,
                transcriptGranularity: TranscriptOutputGranularity?, requestedPlacement: PlacementTarget,
                observedPlacement: FactObservation) throws {
        self.role = role
        self.revision = revision
        self.sampleRatesHz = sampleRatesHz
        self.channels = channels
        self.frameMultipleSamples = frameMultipleSamples
        self.incremental = incremental
        self.emitsPartials = emitsPartials
        self.emitsFinals = emitsFinals
        self.transcriptGranularity = transcriptGranularity
        self.requestedPlacement = requestedPlacement
        self.observedPlacement = observedPlacement
        try validate("$")
    }

    func validate(_ path: String) throws {
        guard !revision.isEmpty else { throw ValidationError("\(path).revision", "must be non-empty") }
        guard !sampleRatesHz.isEmpty, sampleRatesHz.allSatisfy({ ConfigLimits.sampleRateHz.contains($0) }) else {
            throw ValidationError("\(path).sample_rates_hz", "must list at least one rate in 1...768000")
        }
        guard channels == 1 else { throw ValidationError("\(path).channels", "v1 adapters receive mono audio only") }
        if let multiple = frameMultipleSamples, multiple < 1 {
            throw ValidationError("\(path).frame_multiple_samples", "must be positive or null")
        }
        switch (role, transcriptGranularity) {
        case (.asr, nil):
            throw ValidationError("\(path).transcript_granularity", "an ASR adapter must declare its transcript granularity")
        case (.diarization, .some):
            throw ValidationError("\(path).transcript_granularity", "must be null for a diarization adapter")
        default:
            break
        }
    }

    /// Reasons this adapter cannot consume the given stream; empty when compatible.
    public func incompatibilities(sampleRateHz: Int64, channels: Int64, frameSamples: Int64) -> [String] {
        var problems: [String] = []
        if !sampleRatesHz.contains(sampleRateHz) {
            problems.append("stream rate \(sampleRateHz) Hz is not in the accepted rates \(sampleRatesHz)")
        }
        if channels != self.channels { problems.append("stream has \(channels) channels; adapter accepts \(self.channels)") }
        if let multiple = frameMultipleSamples, frameSamples % multiple != 0 {
            problems.append("frame of \(frameSamples) samples is not a multiple of \(multiple)")
        }
        return problems
    }

    public static func read(_ value: JSONValue, _ path: String) throws -> AdapterCapabilities {
        var r = try FieldReader(value, path: path)
        let capabilities = try AdapterCapabilities(
            role: try r.enumeration("role", AdapterRole.self),
            revision: try r.nonEmptyString("revision"),
            sampleRatesHz: try r.array("sample_rates_hz", JSONRead.positive),
            channels: try r.int("channels"),
            frameMultipleSamples: try r.nullableInt("frame_multiple_samples"),
            incremental: try r.bool("incremental"),
            emitsPartials: try r.bool("emits_partials"),
            emitsFinals: try r.bool("emits_finals"),
            transcriptGranularity: try r.nullable("transcript_granularity", JSONRead.enumeration),
            requestedPlacement: try r.enumeration("requested_placement", PlacementTarget.self),
            observedPlacement: try r.required("observed_placement", FactObservation.read))
        try r.finish()
        return capabilities
    }

    public func toJSON() -> JSONValue {
        .object(JSONObject([
            ("role", .string(role.rawValue)), ("revision", .string(revision)),
            ("sample_rates_hz", .array(sampleRatesHz.map(JSONValue.int))), ("channels", .int(channels)),
            ("frame_multiple_samples", frameMultipleSamples.json), ("incremental", .bool(incremental)),
            ("emits_partials", .bool(emitsPartials)), ("emits_finals", .bool(emitsFinals)),
            ("transcript_granularity", transcriptGranularity.map { .string($0.rawValue) } ?? .null),
            ("requested_placement", .string(requestedPlacement.rawValue)),
            ("observed_placement", observedPlacement.toJSON()),
        ]))
    }
}

/// Result of an adapter's idempotent `shutdown()` (plan D1).
public struct AdapterShutdownReport: Sendable, Equatable, JSONRepresentable {
    public enum Status: String, Sendable, CaseIterable { case ok, error }

    public let status: Status
    public let message: String?
    /// Work items still running when shutdown returned; must be 0 for a clean shutdown.
    public let pendingTasks: Int64

    public init(status: Status, message: String?, pendingTasks: Int64) {
        self.status = status
        self.message = message
        self.pendingTasks = pendingTasks
    }

    public static let clean = AdapterShutdownReport(status: .ok, message: nil, pendingTasks: 0)

    public static func read(_ value: JSONValue, _ path: String) throws -> AdapterShutdownReport {
        var r = try FieldReader(value, path: path)
        let report = AdapterShutdownReport(status: try r.enumeration("status", Status.self),
                                           message: try r.nullable("message", JSONRead.nonEmptyString),
                                           pendingTasks: try r.required("pending_tasks", JSONRead.nonNegative))
        try r.finish()
        if report.status == .error, report.message == nil {
            throw ValidationError("\(path).message", "an error shutdown report needs a message")
        }
        return report
    }

    public func toJSON() -> JSONValue {
        .object(JSONObject([("status", .string(status.rawValue)), ("message", message.json),
                            ("pending_tasks", .int(pendingTasks))]))
    }
}
