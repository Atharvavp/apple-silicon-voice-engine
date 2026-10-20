import Foundation

public enum MetricStatus: String, Sendable, CaseIterable {
    case ok
    case notComputable = "not_computable"
    case unsupported, unavailable, error
}

public enum ClockDomain: String, Sendable, CaseIterable {
    case none
    case media
    case monotonic
    case virtual
}

/// One scalar metric with explicit missing-value semantics (plan D6).
///
/// `ok` requires a finite value and a null reason; every other status
/// requires a null value and a non-empty reason. No sentinels, no fake zeros.
public struct MetricRecord: Sendable, Equatable {
    public var status: MetricStatus
    public var value: Double?
    public var unit: String
    public var definitionID: String
    public var sampleCount: Int64
    public var clockDomain: ClockDomain
    public var reason: String?
    public var components: JSONObject

    public init(status: MetricStatus, value: Double?, unit: String, definitionID: String, sampleCount: Int64,
                clockDomain: ClockDomain, reason: String?, components: JSONObject = JSONObject()) throws {
        self.status = status
        self.value = value
        self.unit = unit
        self.definitionID = definitionID
        self.sampleCount = sampleCount
        self.clockDomain = clockDomain
        self.reason = reason
        self.components = components
        try validate(path: "$")
    }

    public static func read(_ value: JSONValue, path: String = "$") throws -> MetricRecord {
        var r = try FieldReader(value, path: path)
        let record = try MetricRecord(
            status: try r.enumeration("status", MetricStatus.self),
            value: try r.nullable("value", JSONRead.number),
            unit: try r.nonEmptyString("unit"),
            definitionID: try r.nonEmptyString("definition_id"),
            sampleCount: try r.required("sample_count", JSONRead.nonNegative),
            clockDomain: try r.enumeration("clock_domain", ClockDomain.self),
            reason: try r.nullable("reason", JSONRead.nonEmptyString),
            components: try r.required("components", JSONRead.object))
        try r.finish()
        return record
    }

    public func validate(path: String) throws {
        if status == .ok {
            guard let value, value.isFinite else {
                throw ValidationError("\(path).value", "status ok requires a finite value")
            }
            guard reason == nil else { throw ValidationError("\(path).reason", "status ok requires a null reason") }
        } else {
            guard value == nil else {
                throw ValidationError("\(path).value", "status \(status.rawValue) requires a null value")
            }
            guard let reason, !reason.isEmpty else {
                throw ValidationError("\(path).reason", "status \(status.rawValue) requires a non-empty reason")
            }
        }
    }

    public func toJSON() -> JSONValue {
        .object(JSONObject([
            ("status", .string(status.rawValue)), ("value", value.map(JSONValue.double) ?? .null),
            ("unit", .string(unit)), ("definition_id", .string(definitionID)), ("sample_count", .int(sampleCount)),
            ("clock_domain", .string(clockDomain.rawValue)), ("reason", reason.json),
            ("components", .object(components)),
        ]))
    }
}
