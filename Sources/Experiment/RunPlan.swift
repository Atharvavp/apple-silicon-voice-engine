import AdapterContracts
import BenchmarkSupport
import Foundation

/// Inputs of one `voicebench run` invocation.
public struct RunRequest: Sendable {
    public var configURL: URL
    public var runsDirectory: URL
    public var runID: String?
    public var overrides: ConfigOverrides
    /// Repository root holding `schemas/v1` and `analysis/src`; discovered when nil.
    public var projectRoot: URL?

    public init(configURL: URL, runsDirectory: URL, runID: String? = nil, overrides: ConfigOverrides = ConfigOverrides(),
                projectRoot: URL? = nil) {
        self.configURL = configURL
        self.runsDirectory = runsDirectory
        self.runID = runID
        self.overrides = overrides
        self.projectRoot = projectRoot
    }
}

/// A file input whose hash was verified against the manifest.
public struct VerifiedInput: Sendable, Equatable {
    public let url: URL
    public let sha256: String
    public let byteCount: Int64
}

/// Everything resolved and verified during preflight (plan C3 step 1).
public struct RunPlan: Sendable {
    public let runID: String
    public let loaded: LoadedConfig
    public let projectRoot: URL
    public let manifestURL: URL
    public let manifestSHA256: String
    public let manifest: DatasetManifest
    public let item: DatasetItem
    public let audio: VerifiedInput
    public let transcript: VerifiedInput?
    public let speakers: VerifiedInput?
    public let script: VerifiedInput?
    public let schemaBundle: SchemaBundle
    public let pythonExecutable: URL

    public var config: RunConfig { loaded.config }
}

/// Digest of the bundled schema files: SHA-256 over sorted lines
/// `"<file name> <file sha256>\n"`. Recorded in sealed run metadata (DEC-008).
public struct SchemaBundle: Sendable, Equatable, JSONRepresentable {
    public static let frozenDigestFile = "schemas/SCHEMA_BUNDLE_V1.sha256"

    public let directory: URL
    public let sha256: String
    public let fileCount: Int
    /// True when the digest equals the committed freeze record.
    public let frozen: Bool

    public static func compute(projectRoot: URL) throws -> SchemaBundle {
        let directory = projectRoot.appendingPathComponent("schemas/v1", isDirectory: true)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".schema.json") }.sorted()
        guard !names.isEmpty else { throw ValidationError(directory.path, "no schema files found") }
        var text = ""
        for name in names {
            text += "\(name) \(try SHA256Hex.file(directory.appendingPathComponent(name)).sha256)\n"
        }
        let digest = SHA256Hex.digest(Data(text.utf8))
        let recorded = try? String(contentsOf: projectRoot.appendingPathComponent(frozenDigestFile), encoding: .utf8)
        let frozen = recorded?.split(whereSeparator: \.isWhitespace).first.map(String.init) == digest
        return SchemaBundle(directory: directory, sha256: digest, fileCount: names.count, frozen: frozen)
    }

    public func toJSON() -> JSONValue {
        .object(JSONObject([("sha256", .string(sha256)), ("file_count", .int(Int64(fileCount))), ("frozen", .bool(frozen))]))
    }
}

public enum ProjectRoot {
    /// Walks up from `start` to the first directory holding `Package.swift`,
    /// `schemas/v1` and `analysis/src`.
    public static func discover(from start: URL) -> URL? {
        var candidate = start.standardizedFileURL
        let fm = FileManager.default
        for _ in 0..<12 {
            if fm.fileExists(atPath: candidate.appendingPathComponent("Package.swift").path),
               fm.fileExists(atPath: candidate.appendingPathComponent("schemas/v1").path),
               fm.fileExists(atPath: candidate.appendingPathComponent("analysis/src/phase0_analysis").path) {
                return candidate
            }
            let parent = candidate.deletingLastPathComponent()
            if parent == candidate { break }
            candidate = parent
        }
        return nil
    }

    public static func resolve(_ explicit: URL?, configURL: URL) throws -> URL {
        if let explicit {
            guard discover(from: explicit) == explicit.standardizedFileURL else {
                throw ExperimentError(.invalidInput, stage: .created, "\(explicit.path) is not the project root")
            }
            return explicit.standardizedFileURL
        }
        let executable = URL(fileURLWithPath: CommandLine.arguments.first ?? "").resolvingSymlinksInPath()
        if let root = discover(from: executable.deletingLastPathComponent()) ?? discover(from: configURL.deletingLastPathComponent()) {
            return root
        }
        throw ExperimentError(.invalidInput, stage: .created,
                              "cannot locate the project root (schemas/v1, analysis/src) from the executable or config path")
    }
}

public enum RunPlanner {
    /// Preflight: every check that can fail without creating a run directory.
    public static func plan(_ request: RunRequest, factory: AdapterFactory) throws -> RunPlan {
        let loaded: LoadedConfig
        do { loaded = try ConfigLoader.load(yamlAt: request.configURL, overrides: request.overrides) } catch {
            throw ExperimentError(.invalidInput, stage: .created, "config \(request.configURL.path): \(error)")
        }
        let runID: String
        do { runID = try request.runID.map { try Identifiers.validateRunID($0, path: "--run-id") } ?? Identifiers.generateRunID() }
        catch { throw ExperimentError(.invalidInput, stage: .created, "\(error)") }
        guard !FileManager.default.fileExists(atPath: request.runsDirectory.appendingPathComponent(runID).path) else {
            throw ExperimentError(.invalidInput, stage: .created, "run \(runID) already exists in \(request.runsDirectory.path)")
        }
        let root = try ProjectRoot.resolve(request.projectRoot, configURL: request.configURL)
        let python = URL(fileURLWithPath: loaded.resolvedPythonExecutable)
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            throw ExperimentError(.invalidInput, stage: .created, "python_executable \(python.path) is not an executable file")
        }
        for (role, selection) in [(AdapterRole.asr, loaded.config.asr), (.diarization, loaded.config.diarization)] {
            guard let entry = factory.entry(selection.id) else {
                throw ExperimentError(.invalidInput, stage: .created, "unknown \(role.rawValue) adapter \"\(selection.id)\"")
            }
            guard entry.role == role else {
                throw ExperimentError(.invalidInput, stage: .created, "adapter \"\(selection.id)\" is a \(entry.role.rawValue) adapter, configured as \(role.rawValue)")
            }
        }

        // Dataset (exit 3).
        func dataset(_ message: String) -> ExperimentError { ExperimentError(.dataset, stage: .created, message) }
        let manifestURL = URL(fileURLWithPath: loaded.resolvedManifestPath)
        let manifestData: Data
        let manifest: DatasetManifest
        do {
            manifestData = try Data(contentsOf: manifestURL)
            manifest = try DatasetManifest.read(try StrictJSON.parse(manifestData))
        } catch { throw dataset("manifest \(manifestURL.path): \(error)") }
        let item: DatasetItem
        do { item = try manifest.item(loaded.config.itemID) } catch { throw dataset("\(error)") }
        let base = manifest.externalRoot.map { PathResolution.resolve($0, relativeTo: manifestURL.deletingLastPathComponent()) }
            .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? manifestURL.deletingLastPathComponent()

        func verified(_ locator: String, _ expected: String, _ what: String) throws -> VerifiedInput {
            let url = URL(fileURLWithPath: PathResolution.resolve(locator, relativeTo: base))
            let (sha, bytes): (String, Int64)
            do { (sha, bytes) = try SHA256Hex.file(url) } catch { throw dataset("\(what) \(url.path) cannot be read: \(error.localizedDescription)") }
            guard sha == expected else { throw dataset("\(what) \(url.path) has SHA-256 \(sha); the manifest declares \(expected)") }
            return VerifiedInput(url: url, sha256: sha, byteCount: bytes)
        }
        let audio = try verified(item.audioPath, item.audioSHA256, "audio")
        let transcript = try item.referenceTextPath.map { try verified($0, item.referenceTextSHA256!, "transcript reference") }
        let speakers = try item.speakerSegmentsPath.map { try verified($0, item.speakerSegmentsSHA256!, "speaker reference") }
        let script = try item.fixtureScriptPath.map { try verified($0, item.fixtureScriptSHA256!, "fixture script") }
        if let descriptor = item.referenceSHA256 {
            let recomputed = DatasetItem.referenceDescriptorHash(transcriptSHA256: item.referenceTextSHA256,
                                                                 speakersSHA256: item.speakerSegmentsSHA256)
            guard recomputed == descriptor else { throw dataset("reference_sha256 does not match the reference file hashes") }
        }
        if loaded.config.references == .required, transcript == nil || speakers == nil {
            throw dataset("scoring.references is required but item \(item.itemID) lacks a transcript or speaker reference")
        }
        for (input, kind) in [(transcript, AnnotationKind.transcript), (speakers, .speakers)] {
            guard let input else { continue }
            let document: AnnotationDocument
            do { document = try AnnotationDocument.read(try StrictJSON.parseFile(input.url)) } catch {
                throw dataset("reference \(input.url.lastPathComponent) is invalid: \(error)")
            }
            let header: AnnotationHeader
            switch (document, kind) {
            case (.transcript(let doc), .transcript): header = doc.header
            case (.speakers(let doc), .speakers): header = doc.header
            default: throw dataset("reference \(input.url.lastPathComponent) is not a \(kind.rawValue) document")
            }
            guard header.sourceID == item.itemID else {
                throw dataset("reference \(input.url.lastPathComponent) is for source \(header.sourceID), not \(item.itemID)")
            }
            guard header.sampleRateHz == item.sampleRateHz, header.durationSamples == item.durationSamples else {
                throw dataset("reference \(input.url.lastPathComponent) timebase \(header.sampleRateHz) Hz / \(header.durationSamples) samples differs from the item's \(item.sampleRateHz) Hz / \(item.durationSamples)")
            }
        }
        let bundle: SchemaBundle
        do { bundle = try SchemaBundle.compute(projectRoot: root) } catch {
            throw ExperimentError(.invalidInput, stage: .created, "schema bundle: \(error)")
        }
        return RunPlan(runID: runID, loaded: loaded, projectRoot: root, manifestURL: manifestURL,
                       manifestSHA256: SHA256Hex.digest(manifestData), manifest: manifest, item: item, audio: audio,
                       transcript: transcript, speakers: speakers, script: script, schemaBundle: bundle,
                       pythonExecutable: python)
    }
}

/// Adapters the runner can construct, by configured ID. A plain table, not a
/// plugin system: tests pass an extended table to substitute an adapter.
public struct AdapterFactory: Sendable {
    public struct Entry: Sendable {
        public let role: AdapterRole
        public let requestedPlacement: PlacementTarget
        public let isMock: Bool
        public let make: @Sendable () -> any StreamingAdapter

        public init(role: AdapterRole, requestedPlacement: PlacementTarget, isMock: Bool,
                    make: @escaping @Sendable () -> any StreamingAdapter) {
            self.role = role
            self.requestedPlacement = requestedPlacement
            self.isMock = isMock
            self.make = make
        }
    }

    public var entries: [String: Entry]

    public init(entries: [String: Entry]) { self.entries = entries }

    public func entry(_ id: String) -> Entry? { entries[id] }
}
