import BenchmarkSupport
import Darwin
import Foundation

/// Runs `python -m phase0_analysis <operation> …` as a local child process
/// (plan C3). It is analysis tooling, not an adapter transport: argument array,
/// no shell, explicit package and schema roots, stdout/stderr streamed straight
/// into bounded log files (no pipe that could fill and deadlock), a wall-clock
/// timeout, and termination on cancellation.
public struct PythonBridge: Sendable {
    public struct Result: Sendable {
        public let exitCode: Int32
        public let stdoutLog: URL
        public let stderrLog: URL
        public let timedOut: Bool
        public let outputLimitHit: Bool

        public var succeeded: Bool { exitCode == 0 && !timedOut && !outputLimitHit }

        public func stdout() -> Data { (try? Data(contentsOf: stdoutLog)) ?? Data() }

        public func stderrTail(_ bytes: Int = 2_000) -> String {
            let data = (try? Data(contentsOf: stderrLog)) ?? Data()
            return String(decoding: data.suffix(bytes), as: UTF8.self)
        }
    }

    public let python: URL
    public let projectRoot: URL
    public let timeoutSeconds: Int64
    public let maxLogBytes: Int64

    public init(python: URL, projectRoot: URL, timeoutSeconds: Int64, maxLogBytes: Int64 = 64 << 20) {
        self.python = python
        self.projectRoot = projectRoot
        self.timeoutSeconds = timeoutSeconds
        self.maxLogBytes = maxLogBytes
    }

    public var environment: [String: String] {
        let mplConfig = FileManager.default.temporaryDirectory.appendingPathComponent("voicebench-mplconfig").path
        return [
            "PYTHONPATH": projectRoot.appendingPathComponent("analysis/src").path,
            "PYTHONNOUSERSITE": "1", "PYTHONDONTWRITEBYTECODE": "1", "PYTHONHASHSEED": "0",
            "MPLBACKEND": "Agg", "MPLCONFIGDIR": mplConfig, "PYTHONUTF8": "1",
            "VOICEBENCH_SCHEMAS": projectRoot.appendingPathComponent("schemas/v1").path,
            "HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1",
            "PATH": "/usr/bin:/bin",
        ]
    }

    /// Runs `python -m phase0_analysis <operation> <arguments…>`.
    public func run(_ operation: String, _ arguments: [String], logDirectory: URL, label: String) async throws -> Result {
        try await runRaw(["-m", "phase0_analysis", operation] + arguments, logDirectory: logDirectory, label: label)
    }

    /// Runs the interpreter with an explicit argument array; logs go to
    /// `<logDirectory>/<label>.stdout.log` / `.stderr.log` (must not exist).
    public func runRaw(_ arguments: [String], logDirectory: URL, label: String) async throws -> Result {
        let stdoutURL = logDirectory.appendingPathComponent("\(label).stdout.log")
        let stderrURL = logDirectory.appendingPathComponent("\(label).stderr.log")
        try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        let stdoutHandle = try exclusiveHandle(stdoutURL)
        let stderrHandle = try exclusiveHandle(stderrURL)
        defer {
            try? stdoutHandle.close()
            try? stderrHandle.close()
        }
        let process = Process()
        process.executableURL = python
        process.arguments = arguments
        process.currentDirectoryURL = projectRoot
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle

        let exited = AsyncFlag()
        process.terminationHandler = { _ in Task { await exited.set() } }
        do { try process.run() } catch {
            throw ExperimentError(.analysis, stage: .scoring, "cannot start \(python.path): \(error.localizedDescription)")
        }
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        var timedOut = false
        var limitHit = false
        var cancelled = false
        while await !exited.value {
            if Task.isCancelled { cancelled = true; break }
            if Date() >= deadline { timedOut = true; break }
            if logSize(stdoutURL) + logSize(stderrURL) > maxLogBytes { limitHit = true; break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        if process.isRunning {
            process.terminate()
            let grace = Date().addingTimeInterval(2)
            while process.isRunning, Date() < grace { usleep(20_000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }
        if cancelled { throw CancellationError() }
        return Result(exitCode: process.terminationStatus, stdoutLog: stdoutURL, stderrLog: stderrURL,
                      timedOut: timedOut, outputLimitHit: limitHit)
    }

    private func exclusiveHandle(_ url: URL) throws -> FileHandle {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard fd >= 0 else { throw RecorderError("cannot create log \(url.path): \(String(cString: strerror(errno)))") }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    private func logSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
    }
}

actor AsyncFlag {
    private(set) var value = false
    func set() { value = true }
}
