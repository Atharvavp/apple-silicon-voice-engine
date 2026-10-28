import BenchmarkSupport
import Foundation

/// Analysis operations on existing runs (plan D3 `validate`/`compare`/`export`).
/// The interpreter and project root come from the run's frozen `config.json`,
/// never from the ambient `python3` or an active virtual environment.
public enum AnalysisCommands {
    public struct Result: Sendable {
        public let exitCode: Int32
        public let stderr: String
        public let output: URL?
    }

    /// Frozen analysis environment of a sealed or partial run.
    public static func bridge(forRun run: URL) throws -> PythonBridge {
        let config = try FieldValue.object(try StrictJSON.parseFile(run.appendingPathComponent("config.json")))
        guard case .object(let paths)? = config["resolved_paths"], case .string(let python)? = paths["python_executable"],
              case .string(let root)? = paths["project_root"] else {
            throw ExperimentError(.invalidInput, stage: .created, "\(run.path)/config.json has no resolved analysis paths")
        }
        var timeout: Int64 = 600
        if case .object(let settings)? = config["settings"], case .object(let runtime)? = settings["runtime"],
           case .int(let value)? = runtime["analysis_timeout_s"] { timeout = value }
        return PythonBridge(python: URL(fileURLWithPath: python), projectRoot: URL(fileURLWithPath: root),
                            timeoutSeconds: max(timeout, 600))
    }

    static func run(_ bridge: PythonBridge, _ operation: String, _ arguments: [String], output: URL?) async throws -> Result {
        let logs = FileManager.default.temporaryDirectory.appendingPathComponent("voicebench-cli-\(UUID().uuidString)")
        let result = try await bridge.run(operation, arguments, logDirectory: logs, label: operation)
        let stderr = String(decoding: (try? Data(contentsOf: result.stderrLog)) ?? Data(), as: UTF8.self)
        try? FileManager.default.removeItem(at: logs)
        let code: Int32 = result.timedOut || result.outputLimitHit ? ExitCodes.analysis : result.exitCode
        return Result(exitCode: code, stderr: stderr, output: output)
    }

    /// Fresh validation of a run into `derived/validation-<id>/validation.json` (never edits the run).
    public static func validateRun(_ run: URL, requireExactEndpoints: Bool) async throws -> Result {
        let id = "validation-\(UUID().uuidString.prefix(12).lowercased())"
        let out = run.appendingPathComponent("derived/\(id)/validation.json")
        var arguments = ["--run", run.path, "--stage", "sealed", "--validation-id", id, "--out", out.path]
        if requireExactEndpoints { arguments.append("--require-exact-endpoints") }
        return try await Self.run(try bridge(forRun: run), "validate", arguments, output: out)
    }

    /// Rescoring into a new `derived/<analysisID>/` directory; the initial metrics are untouched.
    public static func rescore(_ run: URL, analysisID: String) async throws -> Result {
        _ = try Identifiers.validateRunID(analysisID, path: "--analysis-id")
        let out = run.appendingPathComponent("derived/\(analysisID)")
        guard !FileManager.default.fileExists(atPath: out.path) else {
            throw ExperimentError(.invalidInput, stage: .created, "\(out.path) already exists")
        }
        return try await Self.run(try bridge(forRun: run), "score",
                                  ["--run", run.path, "--analysis-id", analysisID, "--out-dir", out.path], output: out)
    }

    public static func compare(_ runs: [URL], profile: String, allowNoncomparable: Bool, out: URL) async throws -> Result {
        guard let first = runs.first else { throw ExperimentError(.invalidInput, stage: .created, "no runs") }
        var arguments = ["--runs"] + runs.map(\.path) + ["--profile", profile, "--out", out.path]
        if allowNoncomparable { arguments.append("--allow-noncomparable") }
        return try await Self.run(try bridge(forRun: first), "compare", arguments, output: out)
    }

    public static func export(_ run: URL, out: URL, format: String) async throws -> Result {
        try await Self.run(try bridge(forRun: run), "export", ["--run", run.path, "--out", out.path, "--format", format],
                           output: out)
    }
}

enum FieldValue {
    static func object(_ value: JSONValue) throws -> JSONObject {
        guard case .object(let object) = value else { throw ValidationError("$", "expected object") }
        return object
    }
}

/// `validate --dataset` (native; plan D4/E5): structure always, plus file
/// existence, hashes and reference documents for ready items. A pending
/// manifest is structurally valid but never runnable.
public enum DatasetValidator {
    public struct Report: Sendable {
        public let status: DatasetStatus
        public let problems: [String]
        public let notes: [String]
    }

    public static func validate(_ url: URL) -> Report {
        let manifest: DatasetManifest
        do { manifest = try DatasetManifest.read(try StrictJSON.parseFile(url)) } catch {
            return Report(status: .pending, problems: ["\(error)"], notes: [])
        }
        var problems: [String] = []
        var notes: [String] = []
        if manifest.status == .pending {
            notes.append("dataset \(manifest.datasetID) is pending: Gate B staging incomplete (\(manifest.provenanceNotes))")
        }
        let base = manifest.externalRoot.map { URL(fileURLWithPath: PathResolution.resolve($0, relativeTo: url.deletingLastPathComponent())) }
            ?? url.deletingLastPathComponent()
        for item in manifest.items {
            let files = [(item.audioPath, item.audioSHA256 as String?), (item.referenceTextPath ?? "", item.referenceTextSHA256),
                         (item.speakerSegmentsPath ?? "", item.speakerSegmentsSHA256),
                         (item.fixtureScriptPath ?? "", item.fixtureScriptSHA256)]
            for (locator, expected) in files where !locator.isEmpty {
                let file = URL(fileURLWithPath: PathResolution.resolve(locator, relativeTo: base))
                guard let digest = try? SHA256Hex.file(file).sha256 else {
                    problems.append("\(item.itemID): \(file.path) cannot be read")
                    continue
                }
                if digest != expected { problems.append("\(item.itemID): \(file.lastPathComponent) hash \(digest) != \(expected ?? "-")") }
            }
            for locator in [item.referenceTextPath, item.speakerSegmentsPath].compactMap({ $0 }) {
                let file = URL(fileURLWithPath: PathResolution.resolve(locator, relativeTo: base))
                if (try? AnnotationDocument.read(try StrictJSON.parseFile(file))) == nil {
                    problems.append("\(item.itemID): \(file.lastPathComponent) is not a valid annotation document")
                }
            }
        }
        notes.append("\(manifest.items.count) items, status \(manifest.status.rawValue), license_verified \(manifest.licenseVerified)")
        return Report(status: manifest.status, problems: problems, notes: notes)
    }
}
