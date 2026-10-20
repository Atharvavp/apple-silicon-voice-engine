import Foundation

/// Error raised while parsing persisted JSON; carries a 1-based line/column.
public struct JSONParseError: Error, CustomStringConvertible, Equatable {
    public let message: String
    public let line: Int
    public let column: Int

    public var description: String { "JSON parse error at line \(line), column \(column): \(message)" }
}

/// Strict RFC 8259 parser for Phase 0 documents.
///
/// Beyond the RFC it rejects: duplicate object keys, invalid UTF-8, lone
/// surrogate escapes, integers outside int64, non-finite numbers, nesting
/// deeper than `maxDepth`, and trailing content. Integers without a fraction
/// or exponent are kept as `.int`; everything else becomes a finite `.double`.
public enum StrictJSON {
    public static let maxDepth = 128

    public static func parse(_ data: Data) throws -> JSONValue {
        guard String(data: data, encoding: .utf8) != nil else {
            throw JSONParseError(message: "document is not valid UTF-8", line: 1, column: 1)
        }
        var parser = Parser(bytes: [UInt8](data))
        parser.skipWhitespace()
        let value = try parser.parseValue(depth: 0)
        parser.skipWhitespace()
        guard parser.atEnd else { throw parser.error("unexpected trailing content") }
        return value
    }

    public static func parse(_ text: String) throws -> JSONValue {
        try parse(Data(text.utf8))
    }

    /// Reads a file with an explicit byte ceiling before parsing.
    public static func parseFile(_ url: URL, maxBytes: Int = 64 * 1024 * 1024) throws -> JSONValue {
        let data = try Data(contentsOf: url)
        guard data.count <= maxBytes else {
            throw JSONParseError(message: "file exceeds \(maxBytes) bytes", line: 1, column: 1)
        }
        return try parse(data)
    }

    private struct Parser {
        let bytes: [UInt8]
        var position = 0

        var atEnd: Bool { position >= bytes.count }

        func error(_ message: String) -> JSONParseError {
            var line = 1
            var column = 1
            for byte in bytes[0..<min(position, bytes.count)] {
                if byte == UInt8(ascii: "\n") {
                    line += 1
                    column = 1
                } else if byte & 0xC0 != 0x80 {
                    column += 1
                }
            }
            return JSONParseError(message: message, line: line, column: column)
        }

        mutating func skipWhitespace() {
            while position < bytes.count {
                switch bytes[position] {
                case 0x20, 0x09, 0x0A, 0x0D: position += 1
                default: return
                }
            }
        }

        mutating func expect(_ literal: String) throws {
            for byte in literal.utf8 {
                guard position < bytes.count, bytes[position] == byte else {
                    throw error("invalid literal; expected \(literal)")
                }
                position += 1
            }
        }

        mutating func parseValue(depth: Int) throws -> JSONValue {
            guard depth <= StrictJSON.maxDepth else { throw error("nesting exceeds \(StrictJSON.maxDepth) levels") }
            guard position < bytes.count else { throw error("unexpected end of input") }
            switch bytes[position] {
            case UInt8(ascii: "{"): return try parseObject(depth: depth)
            case UInt8(ascii: "["): return try parseArray(depth: depth)
            case UInt8(ascii: "\""): return .string(try parseString())
            case UInt8(ascii: "t"): try expect("true"); return .bool(true)
            case UInt8(ascii: "f"): try expect("false"); return .bool(false)
            case UInt8(ascii: "n"): try expect("null"); return .null
            case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return try parseNumber()
            default: throw error("unexpected character")
            }
        }

        mutating func parseObject(depth: Int) throws -> JSONValue {
            position += 1
            var object = JSONObject()
            skipWhitespace()
            if position < bytes.count, bytes[position] == UInt8(ascii: "}") {
                position += 1
                return .object(object)
            }
            while true {
                skipWhitespace()
                guard position < bytes.count, bytes[position] == UInt8(ascii: "\"") else {
                    throw error("expected object key string")
                }
                let keyStart = position
                let key = try parseString()
                skipWhitespace()
                guard position < bytes.count, bytes[position] == UInt8(ascii: ":") else { throw error("expected ':'") }
                position += 1
                skipWhitespace()
                let value = try parseValue(depth: depth + 1)
                guard object.insertNew(key, value) else {
                    position = keyStart
                    throw error("duplicate object key \"\(key)\"")
                }
                skipWhitespace()
                guard position < bytes.count else { throw error("unterminated object") }
                if bytes[position] == UInt8(ascii: ",") {
                    position += 1
                } else if bytes[position] == UInt8(ascii: "}") {
                    position += 1
                    return .object(object)
                } else {
                    throw error("expected ',' or '}'")
                }
            }
        }

        mutating func parseArray(depth: Int) throws -> JSONValue {
            position += 1
            var elements: [JSONValue] = []
            skipWhitespace()
            if position < bytes.count, bytes[position] == UInt8(ascii: "]") {
                position += 1
                return .array(elements)
            }
            while true {
                skipWhitespace()
                elements.append(try parseValue(depth: depth + 1))
                skipWhitespace()
                guard position < bytes.count else { throw error("unterminated array") }
                if bytes[position] == UInt8(ascii: ",") {
                    position += 1
                } else if bytes[position] == UInt8(ascii: "]") {
                    position += 1
                    return .array(elements)
                } else {
                    throw error("expected ',' or ']'")
                }
            }
        }

        mutating func readHex4() throws -> UInt32 {
            guard position + 4 <= bytes.count else { throw error("truncated \\u escape") }
            var value: UInt32 = 0
            for _ in 0..<4 {
                let byte = bytes[position]
                let digit: UInt32
                switch byte {
                case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = UInt32(byte - UInt8(ascii: "0"))
                case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = UInt32(byte - UInt8(ascii: "a") + 10)
                case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = UInt32(byte - UInt8(ascii: "A") + 10)
                default: throw error("invalid hex digit in \\u escape")
                }
                value = value * 16 + digit
                position += 1
            }
            return value
        }

        mutating func parseString() throws -> String {
            position += 1
            var buffer: [UInt8] = []
            while true {
                guard position < bytes.count else { throw error("unterminated string") }
                let byte = bytes[position]
                if byte == UInt8(ascii: "\"") {
                    position += 1
                    return String(decoding: buffer, as: UTF8.self)
                }
                if byte < 0x20 { throw error("unescaped control character in string") }
                if byte != UInt8(ascii: "\\") {
                    buffer.append(byte)
                    position += 1
                    continue
                }
                position += 1
                guard position < bytes.count else { throw error("unterminated escape") }
                let escape = bytes[position]
                position += 1
                switch escape {
                case UInt8(ascii: "\""): buffer.append(0x22)
                case UInt8(ascii: "\\"): buffer.append(0x5C)
                case UInt8(ascii: "/"): buffer.append(0x2F)
                case UInt8(ascii: "b"): buffer.append(0x08)
                case UInt8(ascii: "f"): buffer.append(0x0C)
                case UInt8(ascii: "n"): buffer.append(0x0A)
                case UInt8(ascii: "r"): buffer.append(0x0D)
                case UInt8(ascii: "t"): buffer.append(0x09)
                case UInt8(ascii: "u"):
                    var code = try readHex4()
                    if (0xD800...0xDBFF).contains(code) {
                        guard position + 2 <= bytes.count,
                              bytes[position] == UInt8(ascii: "\\"),
                              bytes[position + 1] == UInt8(ascii: "u") else {
                            throw error("lone high surrogate escape")
                        }
                        position += 2
                        let low = try readHex4()
                        guard (0xDC00...0xDFFF).contains(low) else { throw error("invalid surrogate pair") }
                        code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                    } else if (0xDC00...0xDFFF).contains(code) {
                        throw error("lone low surrogate escape")
                    }
                    guard let scalar = Unicode.Scalar(code) else { throw error("invalid unicode escape") }
                    buffer.append(contentsOf: Array(String(Character(scalar)).utf8))
                default:
                    throw error("invalid escape sequence")
                }
            }
        }

        mutating func parseNumber() throws -> JSONValue {
            let start = position
            var isInteger = true
            if bytes[position] == UInt8(ascii: "-") { position += 1 }
            func digits(_ parser: inout Parser) -> Int {
                var count = 0
                while parser.position < parser.bytes.count,
                      (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(parser.bytes[parser.position]) {
                    parser.position += 1
                    count += 1
                }
                return count
            }
            guard position < bytes.count else { throw error("truncated number") }
            if bytes[position] == UInt8(ascii: "0") {
                position += 1
                if position < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[position]) {
                    throw error("leading zeros are not allowed")
                }
            } else if digits(&self) == 0 {
                throw error("invalid number")
            }
            if position < bytes.count, bytes[position] == UInt8(ascii: ".") {
                isInteger = false
                position += 1
                guard digits(&self) > 0 else { throw error("digit expected after decimal point") }
            }
            if position < bytes.count, bytes[position] == UInt8(ascii: "e") || bytes[position] == UInt8(ascii: "E") {
                isInteger = false
                position += 1
                if position < bytes.count, bytes[position] == UInt8(ascii: "+") || bytes[position] == UInt8(ascii: "-") {
                    position += 1
                }
                guard digits(&self) > 0 else { throw error("digit expected in exponent") }
            }
            let text = String(decoding: bytes[start..<position], as: UTF8.self)
            if isInteger {
                guard let value = Int64(text) else {
                    position = start
                    throw error("integer \(text) is outside the int64 range")
                }
                return .int(value)
            }
            guard let value = Double(text), value.isFinite else {
                position = start
                throw error("number \(text) is not a finite double")
            }
            return .double(value)
        }
    }
}
