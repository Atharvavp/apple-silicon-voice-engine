import Foundation

public struct ArithmeticOverflow: Error, CustomStringConvertible {
    public let operation: String
    public var description: String { "integer overflow in \(operation)" }
}

/// Exact integer arithmetic for sample/time mappings (plan D2 items 5, 8-10).
///
/// All products are formed in 128 bits, so `a * b` never overflows before the
/// division; only a quotient that does not fit int64 is an error.
public enum CheckedMath {
    /// `floor((a * b + addend) / divisor)` for nonnegative inputs and a positive divisor.
    public static func mulDivFloor(_ a: Int64, _ b: Int64, _ divisor: Int64, addend: Int64 = 0) throws -> Int64 {
        guard a >= 0, b >= 0, addend >= 0, divisor > 0 else {
            throw ArithmeticOverflow(operation: "mulDivFloor requires nonnegative operands and a positive divisor")
        }
        var (high, low) = UInt64(a).multipliedFullWidth(by: UInt64(b))
        let (sum, carry) = low.addingReportingOverflow(UInt64(addend))
        low = sum
        if carry { high += 1 }
        guard high < UInt64(divisor) else { throw ArithmeticOverflow(operation: "\(a) * \(b) / \(divisor)") }
        let (quotient, _) = UInt64(divisor).dividingFullWidth((high: high, low: low))
        guard quotient <= UInt64(Int64.max) else { throw ArithmeticOverflow(operation: "\(a) * \(b) / \(divisor)") }
        return Int64(quotient)
    }

    /// Half-up rounding of `n * numerator / denominator`: `floor((n*num + floor(den/2)) / den)`.
    public static func mulDivHalfUp(_ n: Int64, _ numerator: Int64, _ denominator: Int64) throws -> Int64 {
        try mulDivFloor(n, numerator, denominator, addend: denominator / 2)
    }

    public static func add(_ a: Int64, _ b: Int64) throws -> Int64 {
        let (sum, overflow) = a.addingReportingOverflow(b)
        guard !overflow else { throw ArithmeticOverflow(operation: "\(a) + \(b)") }
        return sum
    }

    public static func multiply(_ a: Int64, _ b: Int64) throws -> Int64 {
        let (product, overflow) = a.multipliedReportingOverflow(by: b)
        guard !overflow else { throw ArithmeticOverflow(operation: "\(a) * \(b)") }
        return product
    }

    public static func gcd(_ a: Int64, _ b: Int64) -> Int64 {
        var (x, y) = (abs(a), abs(b))
        while y != 0 { (x, y) = (y, x % y) }
        return x
    }
}

/// Accelerated replay speed as a reduced positive fraction in [1, 100] (plan D2 item 9).
public struct ReplaySpeed: Sendable, Equatable, CustomStringConvertible, JSONRepresentable {
    public let numerator: Int64
    public let denominator: Int64

    public static let maxFractionDigits = 6

    public init(numerator: Int64, denominator: Int64, path: String = "$.replay.speed") throws {
        guard numerator > 0, denominator > 0 else {
            throw ValidationError(path, "speed numerator and denominator must be positive integers")
        }
        guard CheckedMath.gcd(numerator, denominator) == 1 else {
            throw ValidationError(path, "speed fraction \(numerator)/\(denominator) must be in reduced form")
        }
        // 1 <= num/den <= 100  <=>  den <= num <= 100*den
        guard numerator >= denominator, numerator <= (try? CheckedMath.multiply(100, denominator)) ?? Int64.max else {
            throw ValidationError(path, "speed \(numerator)/\(denominator) must be within 1...100")
        }
        self.numerator = numerator
        self.denominator = denominator
    }

    /// Parses an exact decimal such as `4`, `1.5` or `2.000001` (at most six fractional digits).
    public static func parseDecimal(_ text: String, path: String = "--speed") throws -> ReplaySpeed {
        guard text.range(of: #"^[0-9]+(\.[0-9]{1,6})?$"#, options: .regularExpression) != nil else {
            throw ValidationError(path, "speed must be a plain positive decimal with at most \(maxFractionDigits) fractional digits (got \"\(text)\")")
        }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        let fraction = parts.count == 2 ? String(parts[1]) : ""
        var denominator: Int64 = 1
        for _ in 0..<fraction.count { denominator *= 10 }
        guard let numerator = Int64(String(parts[0]) + fraction) else {
            throw ValidationError(path, "speed must be within 1...100 (got \"\(text)\")")
        }
        guard numerator > 0 else { throw ValidationError(path, "speed must be greater than zero (got \"\(text)\")") }
        let divisor = CheckedMath.gcd(numerator, denominator)
        return try ReplaySpeed(numerator: numerator / divisor, denominator: denominator / divisor, path: path)
    }

    public static func read(_ value: JSONValue, _ path: String) throws -> ReplaySpeed {
        var reader = try FieldReader(value, path: path)
        let numerator = try reader.int("num")
        let denominator = try reader.int("den")
        try reader.finish()
        return try ReplaySpeed(numerator: numerator, denominator: denominator, path: path)
    }

    public func toJSON() -> JSONValue {
        .object(JSONObject([("num", .int(numerator)), ("den", .int(denominator))]))
    }

    public var description: String { "\(numerator)/\(denominator)" }
}
