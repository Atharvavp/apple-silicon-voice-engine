import AdapterContracts
import BenchmarkSupport
import Foundation

/// Explicit local roots for Phase 1 real adapters, captured once by the CLI factory
/// (`VOICEBENCH_PHASE1_PROFILES`, `VOICEBENCH_PHASE1_ASSETS`). Nothing is downloaded.
public struct Phase1Roots: Sendable, Equatable {
    public static let profilesVariable = "VOICEBENCH_PHASE1_PROFILES"
    public static let assetsVariable = "VOICEBENCH_PHASE1_ASSETS"

    public let profiles: URL
    public let assets: URL

    public init(profiles: URL, assets: URL) {
        self.profiles = profiles.standardizedFileURL
        self.assets = assets.standardizedFileURL
    }

    /// Both variables must name absolute paths; otherwise real adapters are unavailable.
    public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Phase1Roots? {
        guard let profiles = environment[profilesVariable], profiles.hasPrefix("/"),
              let assets = environment[assetsVariable], assets.hasPrefix("/") else { return nil }
        return Phase1Roots(profiles: URL(fileURLWithPath: profiles, isDirectory: true),
                           assets: URL(fileURLWithPath: assets, isDirectory: true))
    }
}

/// One verified model file: path relative to the assets root, SHA-256 and byte count.
public struct ProfileFile: Sendable, Equatable {
    public let path: String
    public let sha256: String
    public let bytes: Int64
}

/// A small per-configuration profile (one-shot plan section 4). Its identity is the
/// SHA-256 of the exact saved bytes; the config's adapter revision must be
/// `p1:<that digest>`. Framework-specific geometry lives in `settings` and is read by
/// the wrapper that owns it.
public struct ModelProfile: Sendable {
    public static let revisionPrefix = "p1:"

    public let sha256: String
    public let adapterID: String
    public let role: AdapterRole
    public let frameworkName: String
    public let frameworkSource: String
    public let frameworkRevision: String
    public let dependencyLockSHA256: String?
    public let modelRepository: String
    public let modelRevision: String
    public let licenses: [String]
    public let precision: String
    /// Path (relative to the assets root) that the backend loads: a model file/directory or a cache root.
    public let loadPath: String
    public let files: [ProfileFile]
    /// Requested Core ML compute units (`all` in every Phase 1 profile). A request, never an observation.
    public let computeUnits: String
    public let settings: JSONObject
    public let outputProjection: String
    /// Diarization only: native timeline excess past the stream end that may be clipped.
    public let eosTailToleranceSamples: Int64?
    public let notes: String

    public static func read(_ data: Data) throws -> ModelProfile {
        var r = try FieldReader(try StrictJSON.parse(data), path: "$")
        guard try r.int("profile_version") == 1 else { throw ValidationError("$.profile_version", "must be 1") }
        let adapterID = try r.required("adapter_id", Identifiers.stableID)
        let role = try r.enumeration("role", AdapterRole.self)
        var framework = try FieldReader(try r.raw("framework"), path: "$.framework")
        let frameworkName = try framework.nonEmptyString("name")
        let frameworkSource = try framework.nonEmptyString("source")
        let frameworkRevision = try framework.required("revision", Self.gitRevision)
        let lock = try framework.nullable("dependency_lock_sha256", JSONRead.sha256)
        try framework.finish()
        var model = try FieldReader(try r.raw("model"), path: "$.model")
        let repository = try model.nonEmptyString("repository")
        let modelRevision = try model.required("revision", Self.gitRevision)
        let licenses = try model.array("licenses", JSONRead.nonEmptyString)
        let precision = try model.nonEmptyString("precision")
        let loadPath = try model.required("load_path", Self.relativePath)
        let files = try model.array("files") { value, path -> ProfileFile in
            var f = try FieldReader(value, path: path)
            let file = ProfileFile(path: try f.required("path", Self.relativePath), sha256: try f.required("sha256", JSONRead.sha256),
                                   bytes: try f.required("bytes", JSONRead.nonNegative))
            try f.finish()
            return file
        }
        try model.finish()
        let computeUnits = try r.nonEmptyString("compute_units")
        let settings = try r.required("settings", JSONRead.object)
        var output = try FieldReader(try r.raw("output"), path: "$.output")
        let projection = try output.nonEmptyString("projection")
        let tolerance = try output.nullable("eos_tail_tolerance_samples", JSONRead.nonNegative)
        try output.finish()
        let notes = try r.string("notes")
        try r.finish()
        guard !licenses.isEmpty else { throw ValidationError("$.model.licenses", "list at least the original and conversion terms") }
        guard !files.isEmpty else { throw ValidationError("$.model.files", "a profile must list its model files") }
        guard Set(files.map(\.path)).count == files.count else { throw ValidationError("$.model.files", "duplicate path") }
        guard files.contains(where: { $0.path == loadPath || $0.path.hasPrefix(loadPath + "/") }) else {
            throw ValidationError("$.model.load_path", "no listed file lies at or under \(loadPath)")
        }
        guard (role == .diarization) == (tolerance != nil) else {
            throw ValidationError("$.output.eos_tail_tolerance_samples", "required for diarization and null for ASR")
        }
        return ModelProfile(sha256: SHA256Hex.digest(data), adapterID: adapterID, role: role, frameworkName: frameworkName,
                            frameworkSource: frameworkSource, frameworkRevision: frameworkRevision,
                            dependencyLockSHA256: lock, modelRepository: repository, modelRevision: modelRevision,
                            licenses: licenses, precision: precision, loadPath: loadPath, files: files,
                            computeUnits: computeUnits, settings: settings, outputProjection: projection,
                            eosTailToleranceSamples: tolerance, notes: notes)
    }

    public var revision: String { Self.revisionPrefix + sha256 }

    /// Full 40-hex immutable revision (no tags or branch names).
    static func gitRevision(_ value: JSONValue, _ path: String) throws -> String {
        let text = try JSONRead.string(value, path)
        guard text.count == 40, text.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
            throw ValidationError(path, "must be a full 40-character lowercase commit SHA")
        }
        return text
    }

    /// Relative path without `..`, empty or absolute components.
    static func relativePath(_ value: JSONValue, _ path: String) throws -> String {
        let text = try JSONRead.nonEmptyString(value, path)
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        guard !text.hasPrefix("/"), parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw ValidationError(path, "must be a normalized relative path (got \"\(text)\")")
        }
        return text
    }

    // MARK: - Typed access to framework settings

    public func setting(_ key: String) throws -> JSONValue {
        guard let value = settings[key] else { throw ValidationError("$.settings.\(key)", "missing") }
        return value
    }

    public func intSetting(_ key: String) throws -> Int64 { try JSONRead.int(try setting(key), "$.settings.\(key)") }
    public func numberSetting(_ key: String) throws -> Double { try JSONRead.number(try setting(key), "$.settings.\(key)") }
    public func stringSetting(_ key: String) throws -> String { try JSONRead.nonEmptyString(try setting(key), "$.settings.\(key)") }
}

/// Locates, authenticates and verifies a profile and its files before any model loads.
public enum ModelProfileLoader {
    /// Reads `<profiles>/<adapterID>.json`, checks its byte digest against the configured
    /// revision and that it describes this adapter, role and pinned framework source.
    public static func load(adapterID: String, role: AdapterRole, revision: String, frameworkRevision: String,
                            roots: Phase1Roots) throws -> ModelProfile {
        guard revision.hasPrefix(ModelProfile.revisionPrefix) else {
            throw failure(adapterID, "configured revision \"\(revision)\" is not a p1:<sha256> profile revision")
        }
        let url = roots.profiles.appendingPathComponent("\(adapterID).json")
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            throw failure(adapterID, "profile \(url.path) cannot be read: \(error.localizedDescription)")
        }
        let profile: ModelProfile
        do { profile = try ModelProfile.read(data) } catch { throw failure(adapterID, "profile \(url.path): \(error)") }
        guard profile.revision == revision else {
            throw failure(adapterID, "profile digest \(profile.revision) differs from the configured revision \(revision)")
        }
        guard profile.adapterID == adapterID, profile.role == role else {
            throw failure(adapterID, "profile describes \(profile.adapterID) (\(profile.role.rawValue))")
        }
        guard profile.frameworkRevision == frameworkRevision else {
            throw failure(adapterID, "profile pins framework \(profile.frameworkRevision); this binary was built from \(frameworkRevision)")
        }
        return profile
    }

    /// Hashes every listed file and rejects missing, resized, modified or unlisted files
    /// under the load path. Returns the absolute load URL.
    @discardableResult
    public static func verifyAssets(_ profile: ModelProfile, roots: Phase1Roots) throws -> URL {
        let fm = FileManager.default
        for file in profile.files {
            let url = roots.assets.appendingPathComponent(file.path)
            guard fm.fileExists(atPath: url.path) else { throw failure(profile.adapterID, "model file missing: \(file.path)") }
            let (sha, bytes): (String, Int64)
            do { (sha, bytes) = try SHA256Hex.file(url) } catch {
                throw failure(profile.adapterID, "model file \(file.path) cannot be read: \(error.localizedDescription)")
            }
            guard bytes == file.bytes, sha == file.sha256 else {
                throw failure(profile.adapterID, "model file \(file.path) has \(bytes) bytes / \(sha); profile declares \(file.bytes) / \(file.sha256)")
            }
        }
        let loadURL = roots.assets.appendingPathComponent(profile.loadPath)
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: loadURL.path, isDirectory: &isDirectory) else {
            throw failure(profile.adapterID, "load path missing: \(profile.loadPath)")
        }
        if isDirectory.boolValue {
            let listed = Set(profile.files.map(\.path))
            let base = roots.assets.path.hasSuffix("/") ? roots.assets.path : roots.assets.path + "/"
            guard let walker = fm.enumerator(at: loadURL, includingPropertiesForKeys: [.isRegularFileKey]) else {
                throw failure(profile.adapterID, "cannot enumerate \(profile.loadPath)")
            }
            for case let url as URL in walker {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                let relative = String(url.standardizedFileURL.path.dropFirst(base.count))
                if !listed.contains(relative) && url.lastPathComponent != ".DS_Store" {
                    throw failure(profile.adapterID, "unlisted file under the load path: \(relative)")
                }
            }
        }
        return loadURL
    }

    static func failure(_ adapterID: String, _ message: String) -> AdapterError {
        AdapterError(.backend, adapterID: adapterID, stage: .prepare, message)
    }
}
