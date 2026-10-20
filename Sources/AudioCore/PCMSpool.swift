import BenchmarkSupport
import Foundation

/// Identity of a finished Float32 little-endian mono spool file.
public struct PCMSpool: Sendable, Equatable {
    public let url: URL
    public let sampleRateHz: Int64
    public let frameCount: Int64
    public let sha256: String

    public static let encoding = "float32_le"
}

/// Append-only writer for a canonical Float32 LE spool (fixed-block I/O).
public final class PCMSpoolWriter {
    public let url: URL
    private let handle: FileHandle
    public private(set) var frameCount: Int64 = 0
    private var closed = false

    /// Creates the file exclusively; an existing file is never overwritten.
    public init(url: URL) throws {
        self.url = url
        // O_EXCL: creation fails if the path exists (FileManager.createFile would replace it).
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard descriptor >= 0 else {
            throw AudioError(.io, url.path, "cannot create spool file exclusively: \(String(cString: strerror(errno)))")
        }
        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    public func append(_ samples: some Collection<Float>) throws {
        precondition(!closed, "append after close")
        guard !samples.isEmpty else { return }
        var bytes = [UInt8]()
        bytes.reserveCapacity(samples.count * 4)
        for sample in samples {
            let bits = sample.bitPattern.littleEndian
            bytes.append(UInt8(truncatingIfNeeded: bits))
            bytes.append(UInt8(truncatingIfNeeded: bits >> 8))
            bytes.append(UInt8(truncatingIfNeeded: bits >> 16))
            bytes.append(UInt8(truncatingIfNeeded: bits >> 24))
        }
        do { try handle.write(contentsOf: bytes) } catch {
            throw AudioError(.io, url.path, "spool write failed: \(error.localizedDescription)")
        }
        frameCount += Int64(samples.count)
    }

    /// Removes the last `frames` frames (used only for the documented one-frame endpoint trim).
    public func truncateTail(frames: Int64) throws {
        precondition(frames >= 0 && frames <= frameCount)
        frameCount -= frames
        do { try handle.truncate(atOffset: UInt64(frameCount) * 4) } catch {
            throw AudioError(.io, url.path, "spool truncate failed: \(error.localizedDescription)")
        }
        try handle.seekToEnd()
    }

    /// Flushes, closes and hashes the bytes actually on disk.
    public func finish(sampleRateHz: Int64) throws -> PCMSpool {
        closed = true
        do {
            try handle.synchronize()
            try handle.close()
        } catch {
            throw AudioError(.io, url.path, "spool close failed: \(error.localizedDescription)")
        }
        let (digest, bytes) = try SHA256Hex.file(url)
        guard bytes == frameCount * 4 else {
            throw AudioError(.io, url.path, "spool holds \(bytes) bytes; expected \(frameCount * 4)")
        }
        return PCMSpool(url: url, sampleRateHz: sampleRateHz, frameCount: frameCount, sha256: digest)
    }
}

/// Random-access reader over a finished spool.
public final class PCMSpoolReader {
    public let spool: PCMSpool
    private let handle: FileHandle

    public init(_ spool: PCMSpool) throws {
        self.spool = spool
        do { handle = try FileHandle(forReadingFrom: spool.url) } catch {
            throw AudioError(.io, spool.url.path, "cannot open spool: \(error.localizedDescription)")
        }
    }

    deinit { try? handle.close() }

    /// Reads frames `[start, end)` into a fresh array.
    public func read(_ start: Int64, _ end: Int64) throws -> [Float] {
        precondition(0 <= start && start <= end && end <= spool.frameCount, "range outside spool")
        let count = Int(end - start)
        if count == 0 { return [] }
        do {
            try handle.seek(toOffset: UInt64(start) * 4)
            guard let data = try handle.read(upToCount: count * 4), data.count == count * 4 else {
                throw AudioError(.io, spool.url.path, "short spool read at frame \(start)")
            }
            return data.withUnsafeBytes { raw in
                (0..<count).map { Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self))) }
            }
        } catch let error as AudioError {
            throw error
        } catch {
            throw AudioError(.io, spool.url.path, "spool read failed: \(error.localizedDescription)")
        }
    }
}
