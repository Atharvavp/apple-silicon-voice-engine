import Foundation

/// Schema version gate (plan D6 version policy).
///
/// A reader accepts only versions it explicitly supports. A different major
/// version is incompatible; an unknown minor version is also rejected in v1
/// rather than silently tolerated.
public enum SchemaVersion {
    public static let current = "1.0"
    public static let supported: Set<String> = ["1.0"]
    public static let jsonSchemaDialect = "https://json-schema.org/draft/2020-12/schema"

    public static func check(_ value: JSONValue, _ path: String) throws -> String {
        let text = try JSONRead.string(value, path)
        guard text.range(of: #"^[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil else {
            throw ValidationError(path, "schema_version must look like MAJOR.MINOR (got \"\(text)\")")
        }
        guard supported.contains(text) else {
            let major = text.split(separator: ".").first.map(String.init) ?? text
            let reason = major == "1" ? "unsupported minor version" : "incompatible major version"
            throw ValidationError(path, "\(reason) \(text); this reader supports \(supported.sorted().joined(separator: ", "))")
        }
        return text
    }
}
