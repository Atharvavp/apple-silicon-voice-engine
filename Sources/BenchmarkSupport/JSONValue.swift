import Foundation

/// Lossless, order-preserving JSON tree used for every persisted Phase 0 document.
///
/// Integers and fractional numbers are distinct cases so that int64 sample
/// indices and nanosecond timestamps never pass through `Double`.
public enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object(JSONObject)

    public var typeName: String {
        switch self {
        case .null: return "null"
        case .bool: return "boolean"
        case .int: return "integer"
        case .double: return "number"
        case .string: return "string"
        case .array: return "array"
        case .object: return "object"
        }
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }
}

/// JSON object that keeps insertion order and refuses duplicate keys.
public struct JSONObject: Sendable, Equatable {
    public struct Member: Sendable, Equatable {
        public let key: String
        public let value: JSONValue
    }

    public private(set) var members: [Member] = []
    private var index: [String: Int] = [:]

    public init() {}

    /// Builds an object from literal pairs; a duplicated key is a programming error.
    public init(_ pairs: [(String, JSONValue)]) {
        for (key, value) in pairs {
            precondition(index[key] == nil, "duplicate JSON key \(key)")
            index[key] = members.count
            members.append(Member(key: key, value: value))
        }
    }

    public var keys: [String] { members.map(\.key) }
    public var count: Int { members.count }

    public subscript(key: String) -> JSONValue? {
        index[key].map { members[$0].value }
    }

    /// Appends a member; returns false (and leaves the object unchanged) on a duplicate key.
    @discardableResult
    public mutating func insertNew(_ key: String, _ value: JSONValue) -> Bool {
        guard index[key] == nil else { return false }
        index[key] = members.count
        members.append(Member(key: key, value: value))
        return true
    }

    /// Replaces an existing member in place or appends a new one.
    public mutating func set(_ key: String, _ value: JSONValue) {
        if let position = index[key] {
            members[position] = Member(key: key, value: value)
        } else {
            insertNew(key, value)
        }
    }

    public static func == (lhs: JSONObject, rhs: JSONObject) -> Bool {
        lhs.members == rhs.members
    }
}

/// Types that serialize to the shared JSON model.
public protocol JSONRepresentable {
    func toJSON() -> JSONValue
}

extension Optional where Wrapped: JSONRepresentable {
    public func toJSON() -> JSONValue { map { $0.toJSON() } ?? .null }
}

extension Optional where Wrapped == String {
    public var json: JSONValue { map(JSONValue.string) ?? .null }
}

extension Optional where Wrapped == Int64 {
    public var json: JSONValue { map(JSONValue.int) ?? .null }
}

extension Optional where Wrapped == Bool {
    public var json: JSONValue { map(JSONValue.bool) ?? .null }
}
