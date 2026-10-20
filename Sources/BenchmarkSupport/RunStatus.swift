import Foundation

/// Run lifecycle (plan C3): created -> validated -> prepared -> running ->
/// flushing -> scoring -> completed, with failed/cancelled reachable from any
/// nonterminal state.
public enum RunState: String, Sendable, CaseIterable {
    case created, validated, prepared, running, flushing, scoring, completed, failed, cancelled

    public var isTerminal: Bool { self == .completed || self == .failed || self == .cancelled }

    private static let forward: [RunState: RunState] = [
        .created: .validated, .validated: .prepared, .prepared: .running,
        .running: .flushing, .flushing: .scoring, .scoring: .completed,
    ]

    public func canTransition(to next: RunState) -> Bool {
        guard !isTerminal else { return false }
        if next == .failed || next == .cancelled { return true }
        return RunState.forward[self] == next
    }
}

public enum ErrorCategory: String, Sendable, CaseIterable {
    case invalidInput = "invalid_input"
    case dataset
    case audio
    case runtime
    case recorder
    case analysis
    case incompatible
    case validation
    case cancelled
}

public struct RunFailure: Sendable, Equatable {
    public var category: ErrorCategory
    public var stage: RunState
    public var message: String

    public init(category: ErrorCategory, stage: RunState, message: String) {
        self.category = category
        self.stage = stage
        self.message = message.isEmpty ? "unspecified failure" : message
    }

    public static func read(_ value: JSONValue, _ path: String) throws -> RunFailure {
        var r = try FieldReader(value, path: path)
        let failure = RunFailure(category: try r.enumeration("category", ErrorCategory.self),
                                 stage: try r.enumeration("stage", RunState.self),
                                 message: try r.nonEmptyString("message"))
        try r.finish()
        return failure
    }

    public func toJSON() -> JSONValue {
        .object(JSONObject([("category", .string(category.rawValue)), ("stage", .string(stage.rawValue)),
                            ("message", .string(message))]))
    }
}

public struct ArtifactDigest: Sendable, Equatable, JSONRepresentable {
    public var path: String
    public var byteCount: Int64
    public var sha256: String

    public init(path: String, byteCount: Int64, sha256: String) {
        self.path = path
        self.byteCount = byteCount
        self.sha256 = sha256
    }

    public static func read(_ value: JSONValue, _ path: String) throws -> ArtifactDigest {
        var r = try FieldReader(value, path: path)
        let digest = ArtifactDigest(path: try r.nonEmptyString("path"),
                                    byteCount: try r.required("byte_count", JSONRead.nonNegative),
                                    sha256: try r.required("sha256", JSONRead.sha256))
        try r.finish()
        return digest
    }

    public func toJSON() -> JSONValue {
        .object(JSONObject([("path", .string(path)), ("byte_count", .int(byteCount)), ("sha256", .string(sha256))]))
    }
}

/// `status.json`: the only intentionally mutable lifecycle document and the
/// run's commit marker. Terminal statuses carry artifact digests; `status.json`
/// never hashes itself.
public struct RunStatus: Sendable, Equatable {
    public var schemaVersion: String
    public var runID: String
    public var state: RunState
    public var updatedWallTime: String
    public var failure: RunFailure?
    public var lastEventSequence: Int64?
    public var artifacts: [ArtifactDigest]?

    public init(schemaVersion: String = SchemaVersion.current, runID: String, state: RunState, updatedWallTime: String,
                failure: RunFailure?, lastEventSequence: Int64?, artifacts: [ArtifactDigest]?) {
        self.schemaVersion = schemaVersion
        self.runID = runID
        self.state = state
        self.updatedWallTime = updatedWallTime
        self.failure = failure
        self.lastEventSequence = lastEventSequence
        self.artifacts = artifacts
    }

    public static func read(_ value: JSONValue) throws -> RunStatus {
        var r = try FieldReader(value, path: "$")
        let status = RunStatus(
            schemaVersion: try r.required("schema_version", SchemaVersion.check),
            runID: try r.required("run_id") { try Identifiers.validateRunID(JSONRead.string($0, $1), path: $1) },
            state: try r.enumeration("state", RunState.self),
            updatedWallTime: try r.nonEmptyString("updated_wall_time"),
            failure: try r.nullable("failure", RunFailure.read),
            lastEventSequence: try r.nullable("last_event_sequence", JSONRead.nonNegative),
            artifacts: try r.nullable("artifacts") { try JSONRead.array($0, $1, ArtifactDigest.read) })
        try r.finish()
        try status.validate()
        return status
    }

    public func validate() throws {
        let failing = state == .failed || state == .cancelled
        guard failing == (failure != nil) else {
            throw ValidationError("$.failure", "failure must be set exactly for failed/cancelled states")
        }
        if state == .completed, artifacts?.isEmpty ?? true {
            throw ValidationError("$.artifacts", "a completed status must list sealed artifact digests")
        }
        if !state.isTerminal, artifacts != nil {
            throw ValidationError("$.artifacts", "artifact digests are written only with a terminal status")
        }
    }

    public func toJSON() -> JSONValue {
        .object(JSONObject([
            ("schema_version", .string(schemaVersion)), ("run_id", .string(runID)), ("state", .string(state.rawValue)),
            ("updated_wall_time", .string(updatedWallTime)), ("failure", failure.map { $0.toJSON() } ?? .null),
            ("last_event_sequence", lastEventSequence.json),
            ("artifacts", artifacts.map { .array($0.map { $0.toJSON() }) } ?? .null),
        ]))
    }
}
