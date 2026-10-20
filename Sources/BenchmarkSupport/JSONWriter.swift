import CryptoKit
import Foundation

public struct JSONWriteError: Error, CustomStringConvertible {
    public let message: String
    public var description: String { message }
}

/// Serializers for the shared JSON model.
///
/// `canonical` implements the `settings_json_v1` hash-preimage encoding: keys
/// sorted by UTF-8 byte order, compact separators, strings unchanged, only `"`,
/// `\` and C0 controls escaped (`\b \f \n \r \t` short forms, other controls
/// as lowercase `\u00xx`), non-ASCII, solidus and U+2028/U+2029 left literal,
/// integers only. This matches Python's
/// `json.dumps(v, sort_keys=True, separators=(",", ":"), ensure_ascii=False)`
/// for documents without floats; the parity is enforced by analysis tests.
public enum JSONWriter {
    public static let canonicalEncodingID = "settings_json_v1"

    public static func canonical(_ value: JSONValue) throws -> Data {
        var out: [UInt8] = []
        try writeCanonical(value, into: &out)
        return Data(out)
    }

    public static func canonicalSHA256(_ value: JSONValue) throws -> (bytes: Data, sha256: String) {
        let bytes = try canonical(value)
        return (bytes, SHA256Hex.digest(bytes))
    }

    /// Human-readable artifact form: insertion order, two-space indent, trailing newline.
    public static func pretty(_ value: JSONValue) throws -> Data {
        var out: [UInt8] = []
        try writePretty(value, indent: 0, into: &out)
        out.append(0x0A)
        return Data(out)
    }

    /// Single-line form for JSONL records: insertion order, compact, no trailing newline.
    public static func compact(_ value: JSONValue) throws -> Data {
        var out: [UInt8] = []
        try writeCompact(value, sortKeys: false, allowDouble: true, into: &out)
        return Data(out)
    }

    private static func writeCanonical(_ value: JSONValue, into out: inout [UInt8]) throws {
        try writeCompact(value, sortKeys: true, allowDouble: false, into: &out)
    }

    private static func writeCompact(_ value: JSONValue, sortKeys: Bool, allowDouble: Bool, into out: inout [UInt8]) throws {
        switch value {
        case .object(let object):
            out.append(UInt8(ascii: "{"))
            let members = sortKeys
                ? object.members.sorted { Array($0.key.utf8).lexicographicallyPrecedes(Array($1.key.utf8)) }
                : object.members
            for (offset, member) in members.enumerated() {
                if offset > 0 { out.append(UInt8(ascii: ",")) }
                appendString(member.key, into: &out)
                out.append(UInt8(ascii: ":"))
                try writeCompact(member.value, sortKeys: sortKeys, allowDouble: allowDouble, into: &out)
            }
            out.append(UInt8(ascii: "}"))
        case .array(let elements):
            out.append(UInt8(ascii: "["))
            for (offset, element) in elements.enumerated() {
                if offset > 0 { out.append(UInt8(ascii: ",")) }
                try writeCompact(element, sortKeys: sortKeys, allowDouble: allowDouble, into: &out)
            }
            out.append(UInt8(ascii: "]"))
        case .double(let number):
            guard allowDouble else {
                throw JSONWriteError(message: "\(canonicalEncodingID) permits integers only; found \(number)")
            }
            try appendDouble(number, into: &out)
        default:
            try writeScalar(value, into: &out)
        }
    }

    private static func writePretty(_ value: JSONValue, indent: Int, into out: inout [UInt8]) throws {
        let pad = [UInt8](repeating: 0x20, count: (indent + 1) * 2)
        let closePad = [UInt8](repeating: 0x20, count: indent * 2)
        switch value {
        case .object(let object) where object.count > 0:
            out.append(contentsOf: Array("{\n".utf8))
            for (offset, member) in object.members.enumerated() {
                if offset > 0 { out.append(contentsOf: Array(",\n".utf8)) }
                out.append(contentsOf: pad)
                appendString(member.key, into: &out)
                out.append(contentsOf: Array(": ".utf8))
                try writePretty(member.value, indent: indent + 1, into: &out)
            }
            out.append(0x0A)
            out.append(contentsOf: closePad)
            out.append(UInt8(ascii: "}"))
        case .array(let elements) where !elements.isEmpty:
            out.append(contentsOf: Array("[\n".utf8))
            for (offset, element) in elements.enumerated() {
                if offset > 0 { out.append(contentsOf: Array(",\n".utf8)) }
                out.append(contentsOf: pad)
                try writePretty(element, indent: indent + 1, into: &out)
            }
            out.append(0x0A)
            out.append(contentsOf: closePad)
            out.append(UInt8(ascii: "]"))
        case .object:
            out.append(contentsOf: Array("{}".utf8))
        case .array:
            out.append(contentsOf: Array("[]".utf8))
        case .double(let number):
            try appendDouble(number, into: &out)
        default:
            try writeScalar(value, into: &out)
        }
    }

    private static func writeScalar(_ value: JSONValue, into out: inout [UInt8]) throws {
        switch value {
        case .null: out.append(contentsOf: Array("null".utf8))
        case .bool(let flag): out.append(contentsOf: Array((flag ? "true" : "false").utf8))
        case .int(let number): out.append(contentsOf: Array(String(number).utf8))
        case .string(let text): appendString(text, into: &out)
        case .double, .array, .object: preconditionFailure("not a scalar")
        }
    }

    private static func appendDouble(_ number: Double, into out: inout [UInt8]) throws {
        guard number.isFinite else { throw JSONWriteError(message: "non-finite number cannot be written as JSON") }
        out.append(contentsOf: Array(number.description.utf8))
    }

    private static let hexDigits = Array("0123456789abcdef".utf8)

    static func appendString(_ text: String, into out: inout [UInt8]) {
        out.append(UInt8(ascii: "\""))
        for byte in text.utf8 {
            switch byte {
            case 0x22: out.append(contentsOf: [0x5C, 0x22])
            case 0x5C: out.append(contentsOf: [0x5C, 0x5C])
            case 0x08: out.append(contentsOf: [0x5C, UInt8(ascii: "b")])
            case 0x0C: out.append(contentsOf: [0x5C, UInt8(ascii: "f")])
            case 0x0A: out.append(contentsOf: [0x5C, UInt8(ascii: "n")])
            case 0x0D: out.append(contentsOf: [0x5C, UInt8(ascii: "r")])
            case 0x09: out.append(contentsOf: [0x5C, UInt8(ascii: "t")])
            case 0x00..<0x20:
                out.append(contentsOf: Array("\\u00".utf8))
                out.append(hexDigits[Int(byte >> 4)])
                out.append(hexDigits[Int(byte & 0x0F)])
            default:
                out.append(byte)
            }
        }
        out.append(UInt8(ascii: "\""))
    }
}

/// Lowercase hex SHA-256 helpers (CryptoKit).
public enum SHA256Hex {
    public static func digest(_ data: Data) -> String {
        hex(SHA256.hash(data: data))
    }

    public static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Streams a file in fixed blocks so large inputs are never fully loaded.
    public static func file(_ url: URL, blockSize: Int = 1 << 20) throws -> (sha256: String, byteCount: Int64) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var total: Int64 = 0
        while let block = try handle.read(upToCount: blockSize), !block.isEmpty {
            hasher.update(data: block)
            total += Int64(block.count)
        }
        return (hex(hasher.finalize()), total)
    }

    public static func isValid(_ text: String) -> Bool {
        text.utf8.count == 64 && text.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }
}
