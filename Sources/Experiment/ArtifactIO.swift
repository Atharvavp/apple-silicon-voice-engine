import BenchmarkSupport
import CryptoKit
import Darwin
import Foundation

/// One run directory (plan D6 layout). Creation is exclusive, so a run never
/// overwrites another. Individual JSON artifacts are written as
/// `*.tmp` + fsync + exclusive rename; `status.json` is the only file replaced
/// in place and is the commit marker. No multi-file transaction is implied.
public struct RunDirectory: Sendable {
    public let url: URL
    public let runID: String

    public static func create(runsDirectory: URL, runID: String) throws -> RunDirectory {
        do {
            try FileManager.default.createDirectory(at: runsDirectory, withIntermediateDirectories: true)
        } catch {
            throw ExperimentError(.invalidInput, stage: .created, "cannot create runs directory \(runsDirectory.path): \(error.localizedDescription)")
        }
        let url = runsDirectory.appendingPathComponent(runID, isDirectory: true)
        guard mkdir(url.path, 0o755) == 0 else {
            let reason = errno == EEXIST ? "already exists; runs are never overwritten" : String(cString: strerror(errno))
            throw ExperimentError(.invalidInput, stage: .created, "run directory \(url.path) \(reason)")
        }
        let directory = RunDirectory(url: url, runID: runID)
        for sub in ["references", "inputs", "logs", "scratch", "derived"] {
            try FileManager.default.createDirectory(at: url.appendingPathComponent(sub), withIntermediateDirectories: false)
        }
        return directory
    }

    public init(url: URL, runID: String) {
        self.url = url
        self.runID = runID
    }

    public func path(_ relative: String) -> URL { url.appendingPathComponent(relative) }

    /// Writes an immutable artifact; fails if it already exists.
    @discardableResult
    public func writeArtifact(_ relative: String, _ data: Data) throws -> ArtifactDigest {
        try AtomicFile.write(data, to: path(relative), replace: false)
        return ArtifactDigest(path: relative, byteCount: Int64(data.count), sha256: SHA256Hex.digest(data))
    }

    @discardableResult
    public func writeJSON(_ relative: String, _ value: JSONValue) throws -> ArtifactDigest {
        try writeArtifact(relative, try JSONWriter.pretty(value))
    }

    /// Atomically replaces `status.json` after validating the document.
    public func writeStatus(_ status: RunStatus) throws {
        try status.validate()
        try AtomicFile.write(try JSONWriter.pretty(status.toJSON()), to: path("status.json"), replace: true)
    }

    public func digest(_ relative: String) throws -> ArtifactDigest {
        let (sha, bytes) = try SHA256Hex.file(path(relative))
        return ArtifactDigest(path: relative, byteCount: bytes, sha256: sha)
    }

    public func exists(_ relative: String) -> Bool { FileManager.default.fileExists(atPath: path(relative).path) }
}

public enum AtomicFile {
    /// `tmp` (exclusive create) + write + fsync + rename. With `replace == false`
    /// the final rename is exclusive (`RENAME_EXCL`), so an artifact is never overwritten.
    public static func write(_ data: Data, to url: URL, replace: Bool) throws {
        let tmp = url.appendingPathExtension("tmp")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard fd >= 0 else { throw RecorderError("cannot create \(tmp.path): \(String(cString: strerror(errno)))") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            unlink(tmp.path)
            throw RecorderError("cannot write \(tmp.path): \(error.localizedDescription)")
        }
        let result = replace ? rename(tmp.path, url.path) : renamex_np(tmp.path, url.path, UInt32(RENAME_EXCL))
        guard result == 0 else {
            let reason = String(cString: strerror(errno))
            unlink(tmp.path)
            throw RecorderError("cannot finalize \(url.path): \(reason)")
        }
    }
}

/// ISO-8601 wall-clock time with UTC offset; audit metadata only, never used in arithmetic.
public enum WallClock {
    public static func now() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = .current
        return formatter.string(from: Date())
    }
}

/// Append-only JSONL file whose every write happens on one private serial
/// dispatch queue (plan C2: blocking file I/O stays off the cooperative pool).
/// It hashes and counts exactly the bytes written, enforces a byte ceiling,
/// and times each batch write on the run clock.
///
/// `@unchecked Sendable`: all mutable state is touched only on `queue`.
public final class SerialFileWriter: @unchecked Sendable {
    public struct Stats: Sendable, Equatable {
        public var bytes: Int64 = 0
        public var lines: Int64 = 0
        public var batches: Int64 = 0
        public var totalWriteNS: Int64 = 0
        public var maxWriteNS: Int64 = 0
        public var sha256: String = SHA256Hex.digest(Data())
    }

    public let url: URL
    private let queue: DispatchQueue
    private let handle: FileHandle
    private let maxBytes: Int64
    private let clock: any RunClock
    private var hasher = SHA256()
    private var stats = Stats()
    private var closed = false

    public init(url: URL, maxBytes: Int64, clock: any RunClock) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard fd >= 0 else { throw RecorderError("cannot create \(url.path): \(String(cString: strerror(errno)))") }
        self.url = url
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        self.maxBytes = maxBytes
        self.clock = clock
        queue = DispatchQueue(label: "voicebench.io.\(url.lastPathComponent)")
    }

    private func onQueue<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try body() }) }
        }
    }

    public func append(_ data: Data, lines: Int) async throws {
        try await onQueue { try self.appendOnQueue(data, lines: lines) }
    }

    private func appendOnQueue(_ data: Data, lines: Int) throws {
        guard !closed else { throw RecorderError("write after close to \(url.lastPathComponent)") }
        guard stats.bytes + Int64(data.count) <= maxBytes else {
            throw RecorderError("output ceiling of \(maxBytes) bytes reached in \(url.lastPathComponent)")
        }
        let start = clock.nowNS()
        do { try handle.write(contentsOf: data) } catch {
            throw RecorderError("write to \(url.lastPathComponent) failed: \(error.localizedDescription)")
        }
        let elapsed = max(clock.nowNS() - start, 0)
        hasher.update(data: data)
        stats.bytes += Int64(data.count)
        stats.lines += Int64(lines)
        stats.batches += 1
        stats.totalWriteNS += elapsed
        stats.maxWriteNS = max(stats.maxWriteNS, elapsed)
    }

    /// Current counts and the SHA-256 of every byte written so far.
    public func snapshot() async throws -> Stats {
        try await onQueue {
            var copy = self.stats
            copy.sha256 = SHA256Hex.hex(self.hasher.finalize())
            return copy
        }
    }

    public func synchronize() async throws {
        try await onQueue {
            do { try self.handle.synchronize() } catch {
                throw RecorderError("fsync of \(self.url.lastPathComponent) failed: \(error.localizedDescription)")
            }
        }
    }

    public func close() async throws {
        try await onQueue {
            guard !self.closed else { return }
            self.closed = true
            do {
                try self.handle.synchronize()
                try self.handle.close()
            } catch {
                throw RecorderError("close of \(self.url.lastPathComponent) failed: \(error.localizedDescription)")
            }
        }
    }
}
