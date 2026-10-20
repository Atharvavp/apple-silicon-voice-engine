import Foundation
import Yams

/// Converts a single human-authored YAML document into the shared JSON model.
///
/// Policy (plan D3): exactly one document; no anchors (and therefore no
/// aliases), no explicit tags, no merge keys, no duplicate keys, mapping keys
/// must be scalars. Quoted scalars are always strings. Plain scalars resolve
/// with a deliberately narrow rule set: `null`/`~`/empty -> null,
/// `true`/`false` -> boolean, decimal integers -> int64 (overflow rejected),
/// decimal fractions -> finite double. `.nan`, `.inf`, hex/octal integers are
/// rejected (a core-schema tag spelled explicitly on a *key* cannot be told
/// apart after Yams' duplicate check and is tolerated; keys are strings anyway);
/// YAML 1.1 words such as `yes`/`on` stay strings and therefore fail
/// typed validation instead of being silently coerced.
public enum StrictYAML {
    public static let maxBytes = 1 << 20

    public static func load(_ url: URL) throws -> JSONValue {
        let data = try Data(contentsOf: url)
        return try load(data, origin: url.path)
    }

    public static func load(_ data: Data, origin: String = "<yaml>") throws -> JSONValue {
        guard data.count <= maxBytes else {
            throw ValidationError("$", "\(origin): YAML exceeds the \(maxBytes)-byte limit")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw ValidationError("$", "\(origin): YAML is not valid UTF-8")
        }
        let root: Node?
        do {
            root = try Parser(yaml: text).singleRoot()
        } catch {
            throw ValidationError("$", "\(origin): YAML parse error: \(error)")
        }
        guard let root else { throw ValidationError("$", "\(origin): YAML document is empty") }
        return try convert(root, path: "$")
    }

    private static func location(_ node: Node) -> String {
        node.mark.map { " (line \($0.line), column \($0.column))" } ?? ""
    }

    private static func convert(_ node: Node, path: String) throws -> JSONValue {
        if node.anchor != nil {
            throw ValidationError(path, "YAML anchors/aliases are not allowed\(location(node))")
        }
        switch node {
        case .alias:
            throw ValidationError(path, "YAML aliases are not allowed\(location(node))")
        case .scalar(let scalar):
            // libyaml marks every quoted scalar `quoted_implicit`, which Yams reports as the
            // `str` tag; such a scalar is a string either way. Plain scalars must be untagged.
            let tag = scalar.tag.description
            let allowed = tag.isEmpty || (scalar.style != .plain && tag == "tag:yaml.org,2002:str")
            guard allowed else {
                throw ValidationError(path, "explicit YAML tag \(tag) is not allowed\(location(node))")
            }
            if scalar.style != .plain { return .string(scalar.string) }
            return try resolvePlain(scalar.string, path: path, where: location(node))
        case .sequence(let sequence):
            guard sequence.tag.description.isEmpty else {
                throw ValidationError(path, "explicit YAML tag is not allowed\(location(node))")
            }
            return .array(try sequence.enumerated().map { try convert($0.element, path: "\(path)[\($0.offset)]") })
        case .mapping(let mapping):
            guard mapping.tag.description.isEmpty else {
                throw ValidationError(path, "explicit YAML tag is not allowed\(location(node))")
            }
            var object = JSONObject()
            for (keyNode, valueNode) in mapping {
                guard case .scalar(let keyScalar) = keyNode, keyNode.anchor == nil,
                      isUntaggedKey(keyScalar.tag.description) else {
                    throw ValidationError(path, "mapping keys must be untagged scalars\(location(keyNode))")
                }
                let key = keyScalar.string
                if key == "<<" { throw ValidationError(path, "YAML merge keys are not allowed\(location(keyNode))") }
                let value = try convert(valueNode, path: "\(path).\(key)")
                guard object.insertNew(key, value) else {
                    throw ValidationError("\(path).\(key)", "duplicate key\(location(keyNode))")
                }
            }
            return .object(object)
        }
    }

    /// Yams resolves key tags in place while checking duplicate keys (scalar
    /// hashing mutates `Tag.name`), so a plain key reports its core-schema tag.
    /// Keys may carry only those; a custom tag such as `!x` stays visible.
    private static let coreKeyTags: Set<String> = [
        "", "tag:yaml.org,2002:str", "tag:yaml.org,2002:int", "tag:yaml.org,2002:bool",
        "tag:yaml.org,2002:null", "tag:yaml.org,2002:float",
    ]

    private static func isUntaggedKey(_ tag: String) -> Bool { coreKeyTags.contains(tag) }

    private static func resolvePlain(_ text: String, path: String, where location: String) throws -> JSONValue {
        switch text {
        case "", "~", "null", "Null", "NULL": return .null
        case "true", "True", "TRUE": return .bool(true)
        case "false", "False", "FALSE": return .bool(false)
        default: break
        }
        let lowered = text.lowercased()
        if [".nan", ".inf", "+.inf", "-.inf"].contains(lowered) {
            throw ValidationError(path, "non-finite YAML number \(text) is not allowed\(location)")
        }
        if lowered.hasPrefix("0x") || lowered.hasPrefix("0o") || lowered.hasPrefix("-0x") || lowered.hasPrefix("+0x") {
            throw ValidationError(path, "hexadecimal/octal YAML integers are not allowed; use decimal\(location)")
        }
        if isDecimalInteger(text) {
            guard let value = Int64(text.hasPrefix("+") ? String(text.dropFirst()) : text) else {
                throw ValidationError(path, "integer \(text) is outside the int64 range\(location)")
            }
            return .int(value)
        }
        if isDecimalFloat(text) {
            guard let value = Double(text), value.isFinite else {
                throw ValidationError(path, "number \(text) is not a finite double\(location)")
            }
            return .double(value)
        }
        return .string(text)
    }

    private static func isDecimalInteger(_ text: String) -> Bool {
        var body = Substring(text)
        if body.first == "+" || body.first == "-" { body = body.dropFirst() }
        return !body.isEmpty && body.allSatisfy { $0.isASCII && $0.isNumber }
    }

    private static func isDecimalFloat(_ text: String) -> Bool {
        text.range(of: #"^[-+]?(\.[0-9]+|[0-9]+(\.[0-9]*)?)([eE][-+]?[0-9]+)?$"#, options: .regularExpression) != nil
    }
}
