import BenchmarkSupport
import Foundation

/// Repository root derived from this file's location (Tests/BenchmarkSupportTests/...).
let repositoryRoot: URL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

func repoURL(_ relative: String) -> URL { repositoryRoot.appendingPathComponent(relative) }

func jsonFiles(_ relative: String) -> [URL] {
    let directory = repoURL(relative)
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    return names.filter { $0.hasSuffix(".json") }.sorted().map { directory.appendingPathComponent($0) }
}

extension JSONValue {
    /// Key-order-insensitive form for semantic equality checks.
    var keySorted: JSONValue {
        switch self {
        case .object(let object):
            let sorted = object.members.sorted { $0.key < $1.key }.map { ($0.key, $0.value.keySorted) }
            return .object(JSONObject(sorted))
        case .array(let elements):
            return .array(elements.map(\.keySorted))
        default:
            return self
        }
    }
}
