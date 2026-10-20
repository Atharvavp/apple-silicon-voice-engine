import BenchmarkSupport
import Foundation
import Testing

let repositoryRoot: URL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

struct CLIResult {
    let code: Int32
    let stdout: String
    let stderr: String
}

/// Runs the built CLI. A missing binary is a failure, not a skip (run `swift build` first).
/// `VOICEBENCH_BIN` selects another build (as the Python tests do); the default is unchanged.
func voicebench(_ args: [String]) throws -> CLIResult {
    let binary = ProcessInfo.processInfo.environment["VOICEBENCH_BIN"].map { URL(fileURLWithPath: $0) }
        ?? repositoryRoot.appendingPathComponent(".build/debug/voicebench")
    guard FileManager.default.isExecutableFile(atPath: binary.path) else {
        throw ValidationError(binary.path, "voicebench is not built; run `swift build` first")
    }
    let process = Process()
    process.executableURL = binary
    process.arguments = args
    process.currentDirectoryURL = repositoryRoot
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("vb-cli-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    let out = scratch.appendingPathComponent("out")
    let err = scratch.appendingPathComponent("err")
    FileManager.default.createFile(atPath: out.path, contents: nil)
    FileManager.default.createFile(atPath: err.path, contents: nil)
    process.standardOutput = try FileHandle(forWritingTo: out)
    process.standardError = try FileHandle(forWritingTo: err)
    try process.run()
    process.waitUntilExit()
    return CLIResult(code: process.terminationStatus,
                     stdout: (try? String(contentsOf: out, encoding: .utf8)) ?? "",
                     stderr: (try? String(contentsOf: err, encoding: .utf8)) ?? "")
}

func scratchRuns() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("vb-runs-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

struct CLIEndToEndTests {
    @Test func runValidateExportSequence() throws {
        let runs = try scratchRuns()
        let run = try voicebench(["run", "--config", "configs/mock-step.yaml", "--runs-dir", runs.path, "--run-id", "e2e"])
        #expect(run.code == 0, "\(run.stderr)")
        #expect(run.stdout.contains("MOCK"), "the summary labels mock scores")
        #expect(run.stdout.contains("wer: 0.400000"))
        let validate = try voicebench(["validate", "--run", runs.appendingPathComponent("e2e").path])
        #expect(validate.code == 0 && validate.stdout.contains("derived/validation-"))
        let export = try voicebench(["export", "--run", runs.appendingPathComponent("e2e").path, "--out",
                                     runs.appendingPathComponent("export").path])
        #expect(export.code == 0)
        #expect(FileManager.default.fileExists(atPath: runs.appendingPathComponent("export/metrics.csv").path))
    }

    @Test func helpAndVersion() throws {
        let help = try voicebench(["--help"])
        #expect(help.code == 0 && help.stdout.contains("run") && help.stdout.contains("compare"))
        let version = try voicebench(["--version"])
        #expect(version.code == 0 && version.stdout.contains("0.7.0-phase0"))
    }
}

struct ExitCodeTests {
    @Test(arguments: [
        (["run", "--config", "configs/mock-step.yaml"], Int32(2)),                         // missing --runs-dir
        (["run", "--config", "configs/no-such.yaml", "--runs-dir", "/tmp/x"], Int32(2)),
        (["validate", "--run", "/tmp", "--dataset", "x.json"], Int32(2)),                  // exclusive selectors
        (["compare", "--runs", "/tmp/a", "--profile", "accuracy", "--out", "/tmp/o"], Int32(2)),
        (["compare", "--runs", "/tmp/a", "/tmp/b", "--profile", "speed", "--out", "/tmp/o"], Int32(2)),
        (["validate", "--dataset", "datasets/manifests/english-pending.json", "--require-ready"], Int32(9)),
        (["validate", "--run", "/tmp"], Int32(9)),                                          // not a run directory
    ])
    func categorizedExit(_ args: [String], _ expected: Int32) throws {
        let result = try voicebench(args)
        #expect(result.code == expected, "\(args): \(result.stderr)")
        #expect(!result.stderr.isEmpty, "a nonzero exit carries an actionable message")
    }

    @Test func strictEndpointRunExitsWithAudioCategory() throws {
        let runs = try scratchRuns()
        let result = try voicebench(["run", "--config", "configs/mock-step-endpoint-strict.yaml", "--runs-dir", runs.path,
                                     "--run-id", "strict"])
        #expect(result.code == 4)
        #expect(result.stderr.contains("failure: audio"))
    }
}

struct OverrideTests {
    @Test func overridesAreAppliedBeforeValidationAndFrozen() throws {
        let runs = try scratchRuns()
        let ok = try voicebench(["run", "--config", "configs/mock-step.yaml", "--runs-dir", runs.path, "--run-id", "o",
                                 "--frame-ms", "80", "--queue-capacity", "8", "--seed", "11"])
        #expect(ok.code == 0, "\(ok.stderr)")
        guard case .object(let config) = try StrictJSON.parseFile(runs.appendingPathComponent("o/config.json")),
              case .object(let settings)? = config["settings"], case .object(let replay)? = settings["replay"] else {
            Issue.record("config.json missing settings")
            return
        }
        #expect(replay["frame_ms"] == .int(80) && replay["queue_capacity"] == .int(8) && settings["seed"] == .int(11))
        for bad in [["--frame-ms", "25"], ["--queue-capacity", "0"], ["--overflow", "drop_oldest"], ["--mode", "fast"],
                    ["--speed", "4"], ["--python-executable", "relative/python"]] {
            let result = try voicebench(["run", "--config", "configs/mock-step.yaml", "--runs-dir", runs.path] + bad)
            #expect(result.code == 2, "\(bad) must be rejected before any run starts")
        }
    }
}
