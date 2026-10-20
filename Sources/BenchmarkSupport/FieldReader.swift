import Foundation

/// Actionable validation failure located by a JSONPath-like `$.a.b[2]` path.
public struct ValidationError: Error, CustomStringConvertible, Equatable {
    public let path: String
    public let message: String

    public init(_ path: String, _ message: String) {
        self.path = path
        self.message = message
    }

    public var description: String { "\(path): \(message)" }
}

/// Strict typed reader over a JSON object.
///
/// Every key must be read exactly once through `required`/`nullable`, and
/// `finish()` rejects any member that was not consumed (unknown keys). A
/// `nullable` key must still be present: v1 documents spell absent values as
/// explicit `null`, never by omission.
public struct FieldReader {
    public let path: String
    private let object: JSONObject
    private var consumed: Set<String> = []

    public init(_ value: JSONValue, path: String) throws {
        guard case .object(let object) = value else {
            throw ValidationError(path, "expected object, found \(value.typeName)")
        }
        self.object = object
        self.path = path
    }

    public func childPath(_ key: String) -> String { "\(path).\(key)" }

    public func has(_ key: String) -> Bool { object[key] != nil }

    public mutating func raw(_ key: String) throws -> JSONValue {
        consumed.insert(key)
        guard let value = object[key] else { throw ValidationError(childPath(key), "required key is missing") }
        return value
    }

    public mutating func required<T>(_ key: String, _ convert: (JSONValue, String) throws -> T) throws -> T {
        let value = try raw(key)
        if value.isNull { throw ValidationError(childPath(key), "must not be null") }
        return try convert(value, childPath(key))
    }

    public mutating func nullable<T>(_ key: String, _ convert: (JSONValue, String) throws -> T) throws -> T? {
        let value = try raw(key)
        if value.isNull { return nil }
        return try convert(value, childPath(key))
    }

    public func finish() throws {
        for key in object.keys where !consumed.contains(key) {
            throw ValidationError(childPath(key), "unknown key (v1 documents reject unrecognized fields)")
        }
    }

    // MARK: Convenience accessors

    public mutating func string(_ key: String) throws -> String { try required(key, JSONRead.string) }
    public mutating func nonEmptyString(_ key: String) throws -> String { try required(key, JSONRead.nonEmptyString) }
    public mutating func int(_ key: String) throws -> Int64 { try required(key, JSONRead.int) }
    public mutating func bool(_ key: String) throws -> Bool { try required(key, JSONRead.bool) }
    public mutating func nullableString(_ key: String) throws -> String? { try nullable(key, JSONRead.string) }
    public mutating func nullableInt(_ key: String) throws -> Int64? { try nullable(key, JSONRead.int) }
    public mutating func nullableBool(_ key: String) throws -> Bool? { try nullable(key, JSONRead.bool) }

    public mutating func int(_ key: String, in range: ClosedRange<Int64>) throws -> Int64 {
        try required(key) { try JSONRead.int($0, $1, in: range) }
    }

    public mutating func enumeration<E: RawRepresentable>(_ key: String, _: E.Type) throws -> E
        where E.RawValue == String, E: CaseIterable {
        let value = try raw(key)
        if value.isNull { throw ValidationError(childPath(key), "must not be null") }
        return try JSONRead.enumeration(value, childPath(key))
    }

    public mutating func array<T>(_ key: String, _ element: (JSONValue, String) throws -> T) throws -> [T] {
        try required(key) { try JSONRead.array($0, $1, element) }
    }
}

/// Scalar converters shared by every document reader.
public enum JSONRead {
    public static func string(_ value: JSONValue, _ path: String) throws -> String {
        guard case .string(let text) = value else { throw ValidationError(path, "expected string, found \(value.typeName)") }
        return text
    }

    public static func nonEmptyString(_ value: JSONValue, _ path: String) throws -> String {
        let text = try string(value, path)
        guard !text.isEmpty else { throw ValidationError(path, "must be a non-empty string") }
        return text
    }

    public static func int(_ value: JSONValue, _ path: String) throws -> Int64 {
        guard case .int(let number) = value else {
            throw ValidationError(path, "expected integer, found \(value.typeName)")
        }
        return number
    }

    public static func int(_ value: JSONValue, _ path: String, in range: ClosedRange<Int64>) throws -> Int64 {
        let number = try int(value, path)
        guard range.contains(number) else {
            throw ValidationError(path, "must be in \(range.lowerBound)...\(range.upperBound) (got \(number))")
        }
        return number
    }

    public static func nonNegative(_ value: JSONValue, _ path: String) throws -> Int64 {
        try int(value, path, in: 0...Int64.max)
    }

    public static func positive(_ value: JSONValue, _ path: String) throws -> Int64 {
        try int(value, path, in: 1...Int64.max)
    }

    public static func bool(_ value: JSONValue, _ path: String) throws -> Bool {
        guard case .bool(let flag) = value else { throw ValidationError(path, "expected boolean, found \(value.typeName)") }
        return flag
    }

    public static func number(_ value: JSONValue, _ path: String) throws -> Double {
        switch value {
        case .int(let number): return Double(number)
        case .double(let number): return number
        default: throw ValidationError(path, "expected number, found \(value.typeName)")
        }
    }

    public static func enumeration<E: RawRepresentable & CaseIterable>(_ value: JSONValue, _ path: String) throws -> E
        where E.RawValue == String {
        let text = try string(value, path)
        guard let result = E(rawValue: text) else {
            let allowed = E.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
            throw ValidationError(path, "must be one of \(allowed) (got \"\(text)\")")
        }
        return result
    }

    public static func array<T>(_ value: JSONValue, _ path: String, _ element: (JSONValue, String) throws -> T) throws -> [T] {
        guard case .array(let elements) = value else { throw ValidationError(path, "expected array, found \(value.typeName)") }
        return try elements.enumerated().map { try element($0.element, "\(path)[\($0.offset)]") }
    }

    public static func sha256(_ value: JSONValue, _ path: String) throws -> String {
        let text = try string(value, path)
        guard SHA256Hex.isValid(text) else { throw ValidationError(path, "must be 64 lowercase hex characters") }
        return text
    }

    public static func object(_ value: JSONValue, _ path: String) throws -> JSONObject {
        guard case .object(let object) = value else { throw ValidationError(path, "expected object, found \(value.typeName)") }
        return object
    }
}
