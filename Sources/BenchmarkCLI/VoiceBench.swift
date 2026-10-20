import ArgumentParser
import AudioCore
import BenchmarkSupport
import Foundation
import Experiment
import MockAdapters

/// Package version reported by `voicebench --version`.
enum BuildInfo {
    static let version = VoiceBenchVersion.current
}

@main
struct VoiceBench: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "voicebench",
        abstract: "Phase 0 streaming speech benchmark harness (mock adapters only).",
        discussion: """
        One experiment (one dataset item, one stream) per process. Mock adapters only:
        scores validate the harness, never speech-recognition quality.
        Exit codes: 0 ok, 2 invalid input, 3 dataset, 4 audio, 5 runtime/adapter,
        6 recorder, 7 analysis, 8 incompatible comparison, 9 validation, 130 interrupted.
        """,
        version: "\(BuildInfo.version) (schema \(SchemaVersion.current))",
        subcommands: [RunCommand.self, ValidateCommand.self, CompareCommand.self, ExportCommand.self, Dev.self]
    )

    /// Plan G3: invalid CLI input exits 2 (ArgumentParser's default usage code is 64).
    static func main() async {
        do {
            var command = try parseAsRoot()
            if var asyncCommand = command as? AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                try command.run()
            }
        } catch {
            if exitCode(for: error) == .validationFailure {
                FileHandle.standardError.write(Data((fullMessage(for: error) + "\n").utf8))
                Foundation.exit(2)
            }
            exit(withError: error)
        }
    }
}

/// Hidden developer tools used by the cross-language schema tests.
struct Dev: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Developer tools for schema parity tests.",
        shouldDisplay: false,
        subcommands: [RoundTrip.self, Canonical.self, ConfigSettings.self, PrepareAudio.self, RuntimeStage.self]
    )
}

struct RoundTrip: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "roundtrip",
        abstract: "Strictly read a JSON document as KIND, validate it and re-emit it.")

    @Option(help: "Document kind: \((DocumentKind.allCases.map(\.rawValue) + ["fixture-script"]).joined(separator: ", "))")
    var kind: String

    @Option(help: "Input JSON path.")
    var input: String

    @Option(help: "Output JSON path (must not exist).")
    var output: String

    func run() throws {
        let value = try StrictJSON.parseFile(URL(fileURLWithPath: input))
        let reencoded: JSONValue
        if kind == "fixture-script" {
            reencoded = try FixtureScript.read(value).toJSON()
        } else {
            guard let documentKind = DocumentKind(rawValue: kind) else {
                throw ValidationError("unknown kind \(kind)")
            }
            reencoded = try documentKind.roundTrip(value)
        }
        let encoded = try JSONWriter.pretty(reencoded)
        try encoded.write(to: URL(fileURLWithPath: output), options: .withoutOverwriting)
    }
}

struct Canonical: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Print the settings_json_v1 canonical bytes of a JSON document.")

    @Option(help: "Input JSON path.")
    var input: String

    func run() throws {
        let value = try StrictJSON.parseFile(URL(fileURLWithPath: input))
        FileHandle.standardOutput.write(try JSONWriter.canonical(value))
    }
}

struct ConfigSettings: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config-settings",
        abstract: "Load a YAML config (with overrides) and print its settings preimage and SHA-256.")

    @Option(help: "Authored YAML config.")
    var config: String

    @Option(help: "Replay mode override.")
    var mode: String?

    @Option(name: .customLong("frame-ms"), help: "Frame size override.")
    var frameMS: Int64?

    @Option(help: "Accelerated speed override (decimal).")
    var speed: String?

    func run() throws {
        let overrides = ConfigOverrides(
            mode: try mode.map { value in
                guard let parsed = ReplayMode(rawValue: value) else { throw ValidationError("invalid --mode \(value)") }
                return parsed
            },
            frameMS: frameMS, speedDecimal: speed)
        let loaded = try ConfigLoader.load(yamlAt: URL(fileURLWithPath: config), overrides: overrides)
        let (bytes, digest) = try loaded.settingsBytesAndHash()
        FileHandle.standardOutput.write(bytes)
        FileHandle.standardOutput.write(Data("\n\(digest)\n".utf8))
    }
}

struct PrepareAudio: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "prepare-audio",
        abstract: "Decode/convert a WAV into a scratch directory and print source + conversion records as JSON.")

    @Option(help: "Input WAV path.")
    var input: String

    @Option(name: .customLong("target-rate"), help: "Target sample rate in Hz.")
    var targetRate: Int64 = 16_000

    @Option(help: "Empty or new scratch directory for the spool files.")
    var scratch: String

    @Flag(help: "Use the strict endpoint policy (any endpoint correction is an error).")
    var strict = false

    func run() throws {
        let directory = URL(fileURLWithPath: scratch, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let input = URL(fileURLWithPath: self.input)
        let prepared = try AudioPreparer.prepare(source: input, sourceID: input.deletingPathExtension().lastPathComponent,
                                                 targetRateHz: targetRate, scratchDirectory: directory,
                                                 endpointPolicy: strict ? .strict : .allowOneFrame)
        let output = JSONValue.object(JSONObject([
            ("source", prepared.source.toJSON()), ("conversion", prepared.conversion.toJSON()),
            ("spool", .object(JSONObject([("frame_count", .int(prepared.spool.frameCount)),
                                          ("sha256", .string(prepared.spool.sha256))]))),
        ]))
        FileHandle.standardOutput.write(try JSONWriter.pretty(output))
    }
}

/// Runs only the runtime stage (no scoring, no sealing). Used by the Python
/// trace/validation tests to obtain genuine unsealed artifacts; the run stays
/// in a nonterminal state and can never be mistaken for a completed run.
struct RuntimeStage: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "runtime-stage",
        abstract: "Run preflight + runtime stage only; leaves an unsealed, nonterminal run directory.")

    @Option(help: "Authored YAML config.") var config: String
    @Option(name: .customLong("runs-dir"), help: "Directory for run directories.") var runsDir: String
    @Option(name: .customLong("run-id"), help: "Explicit run ID.") var runID: String

    func run() async throws {
        let request = RunRequest(configURL: URL(fileURLWithPath: config), runsDirectory: URL(fileURLWithPath: runsDir),
                                 runID: runID)
        let (outcome, _) = await ExperimentRunner().runtimeOnly(request)
        if let failure = outcome.failure {
            FileHandle.standardError.write(Data("runtime-stage failed: \(failure)\n".utf8))
            throw ExitCode(failure.exitCode)
        }
        print(outcome.directory?.path ?? "")
    }
}
