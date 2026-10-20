import ArgumentParser
import BenchmarkSupport
import Experiment
import Foundation

private func finish(_ result: AnalysisCommands.Result, label: String) throws {
    if !result.stderr.isEmpty { FileHandle.standardError.write(Data(result.stderr.utf8)) }
    if let output = result.output, result.exitCode == 0 || FileManager.default.fileExists(atPath: output.path) {
        print("\(label): \(output.path)")
    }
    if result.exitCode != 0 { throw ExitCode(result.exitCode) }
}

private func fail(_ message: String, _ code: Int32) -> ExitCode {
    FileHandle.standardError.write(Data("voicebench: \(message)\n".utf8))
    return ExitCode(code)
}

/// `voicebench validate` (plan D3): exactly one of --run, --dataset, --suite.
struct ValidateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "validate", abstract: "Validate a run, a dataset manifest, or the Gate A evidence suite.")

    @Option(help: "Run directory to validate (writes derived/validation-<id>/validation.json).") var run: String?
    @Flag(help: "Rescore the run into derived/<analysis-id>/ (initial metrics are never changed).") var rescore = false
    @Option(name: .customLong("analysis-id"), help: "Rescore directory name [A-Za-z0-9_-].") var analysisID: String?
    @Flag(name: .customLong("require-exact-endpoints"), help: "Fail a run whose conversion needed an endpoint correction.")
    var requireExactEndpoints = false
    @Option(help: "Dataset manifest to validate.") var dataset: String?
    @Flag(name: .customLong("require-ready"), help: "Fail unless the dataset is ready (runnable).") var requireReady = false
    @Option(help: "Validation suite name (gate-a).") var suite: String?
    @Option(name: .customLong("evidence-dir"), help: "Evidence directory for --suite.") var evidenceDir: String?

    func validate() throws {
        let selectors = [run != nil, dataset != nil, suite != nil].filter { $0 }.count
        guard selectors == 1 else { throw ValidationError("choose exactly one of --run, --dataset, --suite") }
        if rescore || analysisID != nil || requireExactEndpoints, run == nil {
            throw ValidationError("--rescore, --analysis-id and --require-exact-endpoints apply to --run only")
        }
        if requireReady, dataset == nil { throw ValidationError("--require-ready applies to --dataset only") }
        if suite != nil, evidenceDir == nil { throw ValidationError("--suite needs --evidence-dir") }
    }

    func run() async throws {
        if let run {
            let url = URL(fileURLWithPath: run)
            guard FileManager.default.fileExists(atPath: url.appendingPathComponent("config.json").path) else {
                throw fail("\(run) is not a run directory (no config.json)", ExitCodes.validation)
            }
            do {
                if rescore {
                    let id = analysisID ?? "rescore-\(UUID().uuidString.prefix(8).lowercased())"
                    try finish(try await AnalysisCommands.rescore(url, analysisID: id), label: "rescore")
                } else {
                    try finish(try await AnalysisCommands.validateRun(url, requireExactEndpoints: requireExactEndpoints),
                               label: "validation")
                }
            } catch let error as ExperimentError {
                throw fail(error.description, error.exitCode)
            }
            return
        }
        if let dataset {
            let report = DatasetValidator.validate(URL(fileURLWithPath: dataset))
            report.notes.forEach { print($0) }
            report.problems.forEach { FileHandle.standardError.write(Data("problem: \($0)\n".utf8)) }
            if !report.problems.isEmpty { throw ExitCode(ExitCodes.validation) }
            if requireReady, report.status != .ready {
                throw fail("dataset is not ready (Gate B pending); --require-ready fails", ExitCodes.validation)
            }
            print("dataset: structurally valid\(report.status == .ready ? " and ready" : "")")
            return
        }
        try await GateASuite.run(suite: suite!, evidence: URL(fileURLWithPath: evidenceDir!))
    }
}

struct CompareCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "compare", abstract: "Compare completed runs under one profile (exit 8 when not comparable).")

    @Option(parsing: .upToNextOption, help: "Two or more run directories.") var runs: [String]
    @Option(help: "accuracy | latency | resources") var profile: String
    @Flag(name: .customLong("allow-noncomparable"), help: "Emit labelled side-by-side rows; never a ranking.")
    var allowNoncomparable = false
    @Option(help: "New (or empty) output directory.") var out: String

    func validate() throws {
        guard runs.count >= 2 else { throw ValidationError("--runs needs at least two run directories") }
        guard ["accuracy", "latency", "resources"].contains(profile) else {
            throw ValidationError("--profile must be accuracy, latency or resources")
        }
    }

    func run() async throws {
        let outURL = URL(fileURLWithPath: out)
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: outURL.path), !contents.isEmpty {
            throw fail("\(out) exists and is not empty; outputs are never overwritten", ExitCodes.invalidInput)
        }
        do {
            try finish(try await AnalysisCommands.compare(runs.map { URL(fileURLWithPath: $0) }, profile: profile,
                                                          allowNoncomparable: allowNoncomparable, out: outURL),
                       label: "comparison")
        } catch let error as ExperimentError {
            throw fail(error.description, error.exitCode)
        }
    }
}

struct ExportCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export", abstract: "Export one run's metrics, predictions, timing and resources as CSV/PNG.")

    @Option(help: "Run directory.") var run: String
    @Option(help: "New (or empty) output directory.") var out: String
    @Option(help: "csv | plots | all") var format: String = "all"

    func validate() throws {
        guard ["csv", "plots", "all"].contains(format) else { throw ValidationError("--format must be csv, plots or all") }
    }

    func run() async throws {
        let outURL = URL(fileURLWithPath: out)
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: outURL.path), !contents.isEmpty {
            throw fail("\(out) exists and is not empty; outputs are never overwritten", ExitCodes.invalidInput)
        }
        let runURL = URL(fileURLWithPath: run)
        guard FileManager.default.fileExists(atPath: runURL.appendingPathComponent("metrics.json").path) else {
            throw fail("\(run) has no metrics.json (failed or unscored run)", ExitCodes.validation)
        }
        do {
            try finish(try await AnalysisCommands.export(runURL, out: outURL, format: format), label: "export")
        } catch let error as ExperimentError {
            throw fail(error.description, error.exitCode)
        }
    }
}

/// Placeholder until M7 wires the acceptance orchestration; never reports a pass.
enum GateASuite {
    static func run(suite: String, evidence: URL) async throws {
        throw fail("validation suite \(suite) is not available yet", ExitCodes.validation)
    }
}
