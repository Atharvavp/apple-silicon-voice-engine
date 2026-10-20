import Foundation

/// Identifier rules shared by runs, sources, events and artifacts.
public enum Identifiers {
    /// Explicit run IDs: `[A-Za-z0-9_-]{1,80}`; generated IDs are lowercase UUIDs.
    public static func validateRunID(_ text: String, path: String = "$.run_id") throws -> String {
        guard (1...80).contains(text.utf8.count),
              text.utf8.allSatisfy({ isAlphanumeric($0) || $0 == UInt8(ascii: "_") || $0 == UInt8(ascii: "-") }) else {
            throw ValidationError(path, "run IDs must match [A-Za-z0-9_-]{1,80} (got \"\(text)\")")
        }
        return text
    }

    public static func generateRunID() -> String { UUID().uuidString.lowercased() }

    /// Stable logical IDs (sources, items, segments, adapters): printable ASCII
    /// without whitespace or path separators other than `/`, 1...200 bytes.
    public static func validateStableID(_ text: String, path: String) throws -> String {
        guard (1...200).contains(text.utf8.count),
              text.utf8.allSatisfy({ isAlphanumeric($0) || Array("_-./:".utf8).contains($0) }),
              !text.contains(".."), !text.hasPrefix("/") else {
            throw ValidationError(path, "stable IDs must be 1-200 chars of [A-Za-z0-9_-./:] without '..' or a leading '/' (got \"\(text)\")")
        }
        return text
    }

    public static func stableID(_ value: JSONValue, _ path: String) throws -> String {
        try validateStableID(JSONRead.string(value, path), path: path)
    }

    /// Simplified BCP-47 shape check (language subtag plus optional subtags).
    public static func languageTag(_ value: JSONValue, _ path: String) throws -> String {
        let text = try JSONRead.string(value, path)
        guard text.range(of: #"^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$"#, options: .regularExpression) != nil else {
            throw ValidationError(path, "must be a BCP-47 language tag such as en-US or hi-IN (got \"\(text)\")")
        }
        return text
    }

    private static func isAlphanumeric(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
    }
}
