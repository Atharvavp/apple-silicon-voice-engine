import ArgumentParser
import BenchmarkSupport
import Dispatch
import Experiment
import Foundation

/// `voicebench run` (plan D3): preflight, runtime, scoring, sealing.
struct RunCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run", abstract: "Run one experiment and seal its artifacts (exit codes: see voicebench --help).")

    @Option(help: "Authored YAML config.") var config: String
    @Option(name: .customLong("runs-dir"), help: "Directory that receives the run directory.") var runsDir: String
    @Option(name: .customLong("run-id"), help: "Explicit run ID [A-Za-z0-9_-]{1,80}; a UUID by default.") var runID: String?
    @Option(help: "Replay mode override: realtime | accelerated | step.") var mode: String?
    @Option(name: .customLong("frame-ms"), help: "Frame size override: 10 | 20 | 40 | 80.") var frameMS: Int64?
    @Option(help: "Accelerated speed as a decimal (1...100, at most 6 fractional digits).") var speed: String?
    @Option(name: .customLong("queue-capacity"), help: "Audio queue capacity override (1...4096).") var queueCapacity: Int64?
    @Option(help: "Overflow policy override: block | drop_newest.") var overflow: String?
    @Option(help: "Seed override (0...Int64.max).") var seed: Int64?
    @Option(name: .customLong("python-executable"), help: "Absolute analysis interpreter path override.") var pythonExecutable: String?

    func run() async throws {
        let overrides: ConfigOverrides
        do {
            overrides = ConfigOverrides(
                mode: try mode.map { value in
                    guard let parsed = ReplayMode(rawValue: value) else {
                        throw BenchmarkSupport.ValidationError("--mode", "must be realtime, accelerated or step")
                    }
                    return parsed
                },
                frameMS: frameMS, speedDecimal: speed, queueCapacity: queueCapacity,
                overflow: try overflow.map { value in
                    guard let parsed = OverflowPolicy(rawValue: value) else {
                        throw BenchmarkSupport.ValidationError("--overflow", "must be block or drop_newest")
                    }
                    return parsed
                },
                seed: seed, pythonExecutable: pythonExecutable)
        } catch {
            FileHandle.standardError.write(Data("voicebench run: \(error)\n".utf8))
            throw ExitCode(ExitCodes.invalidInput)
        }
        let request = RunRequest(configURL: URL(fileURLWithPath: config), runsDirectory: URL(fileURLWithPath: runsDir),
                                 runID: runID, overrides: overrides)
        let task = Task { await ExperimentRunner().run(request) }
        let signals = SignalCancellation(task: task)
        let outcome = await task.value
        signals.stop()
        RunSummary.print(outcome)
        if outcome.exitCode != 0 { throw ExitCode(outcome.exitCode) }
    }
}

/// SIGINT/SIGTERM -> cooperative cancellation of the run task (plan C3). The
/// handlers run on a dispatch source, never inside a signal handler.
final class SignalCancellation: Sendable {
    private let sources: [any DispatchSourceSignal]

    init(task: Task<RunOutcome, Never>) {
        let queue = DispatchQueue(label: "voicebench.signals")
        sources = [SIGINT, SIGTERM].map { number in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
            source.setEventHandler {
                FileHandle.standardError.write(Data("voicebench: signal \(number) received; cancelling the run\n".utf8))
                task.cancel()
            }
            source.resume()
            return source
        }
    }

    func stop() {
        sources.forEach { $0.cancel() }
    }
}

enum RunSummary {
    static func print(_ outcome: RunOutcome) {
        var lines: [String] = []
        lines.append("run: \(outcome.runID ?? "-")  state: \(outcome.state.rawValue)  exit: \(outcome.exitCode)")
        if let directory = outcome.directory { lines.append("artifacts: \(directory.path)") }
        if let failure = outcome.failure {
            lines.append("failure: \(failure.category.rawValue) at \(failure.stage.rawValue): \(failure.message)")
        }
        if case .object(let metrics)? = outcome.summary {
            let mock = metrics["mock"] == .bool(true)
            lines.append(mock ? "adapters: MOCK (scores validate the harness, not speech recognition)" : "adapters: real")
            if case .object(let accuracy)? = metrics["accuracy"] {
                for key in ["wer", "cer", "der", "jer"] {
                    guard case .object(let record)? = accuracy[key] else { continue }
                    let value: String
                    switch (record["status"], record["value"]) {
                    case (.string("ok"), .double(let v)?): value = String(format: "%.6f", v)
                    case (.string(let status)?, _): value = "\(status) (\(record["reason"].map { "\($0)" } ?? ""))"
                    default: value = "?"
                    }
                    lines.append("  \(key): \(value)")
                }
            }
            if case .object(let integrity)? = metrics["data_integrity"], case .object(let loss)? = integrity["data_loss"],
               loss["value"] == .double(1) {
                lines.append("  DATA LOSS: dropped audio; excluded from accuracy rankings")
            }
            if case .object(let integrity)? = metrics["data_integrity"],
               case .object(let endpoint)? = integrity["endpoint_corrected_frames"],
               case .object(let components)? = endpoint["components"],
               case .string(let status)? = components["endpoint_status"], status.contains("one_frame") {
                lines.append("  endpoint correction disclosed: \(status)")
            }
        }
        Swift.print(lines.joined(separator: "\n"))
    }
}
