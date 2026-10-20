import AudioCore
import BenchmarkSupport
import CryptoKit
import Foundation

/// Slices a finished spool into immutable chunks following a `ChunkPlan`.
///
/// Each chunk copies its samples out of the file into private storage. Read
/// errors always throw (there is deliberately no non-throwing `next()`, which
/// would turn a failed read into a silently shortened stream). Every byte handed
/// out is hashed; after the last chunk, `verifyAgainstSpool()` proves the
/// replayed audio is exactly the hashed spool.
public struct FrameIterator {
    private let reader: PCMSpoolReader
    private var entries: AnyIterator<ChunkPlan.Entry>
    private let identity: ChunkIdentity
    private var hasher = SHA256()
    public private(set) var producedFrames: Int64 = 0
    public private(set) var finished = false

    public struct ChunkIdentity: Sendable {
        public let runID: String
        public let streamID: String
        public let sourceID: String
        public let mode: ReplayMode

        public init(runID: String, streamID: String, sourceID: String, mode: ReplayMode) {
            self.runID = runID
            self.streamID = streamID
            self.sourceID = sourceID
            self.mode = mode
        }
    }

    public init(spool: PCMSpool, frameSamples: Int64, identity: ChunkIdentity) throws {
        reader = try PCMSpoolReader(spool)
        entries = try ChunkPlan(totalFrames: spool.frameCount, frameSamples: frameSamples).makeIterator()
        self.identity = identity
    }

    /// Next chunk, or nil once the plan is exhausted.
    public mutating func nextChunk() throws -> AudioChunk? {
        guard let entry = entries.next() else {
            finished = true
            return nil
        }
        let samples = try reader.read(entry.start, entry.end)
        // Hash the spool encoding (Float32 little-endian) of exactly the samples handed out.
        #if _endian(little)
        samples.withUnsafeBytes { hasher.update(bufferPointer: $0) }
        #else
        for sample in samples {
            withUnsafeBytes(of: sample.bitPattern.littleEndian) { hasher.update(bufferPointer: $0) }
        }
        #endif
        producedFrames += Int64(samples.count)
        return try AudioChunk(
            runID: identity.runID, streamID: identity.streamID, sourceID: identity.sourceID, chunkIndex: entry.index,
            sampleRateHz: reader.spool.sampleRateHz, startSample: entry.start, endSample: entry.end,
            replayMode: identity.mode, samples: OwnedMonoPCM(copying: samples))
    }

    /// Throws unless every frame was produced and the produced bytes hash to the spool's SHA-256.
    public func verifyAgainstSpool() throws {
        guard finished, producedFrames == reader.spool.frameCount else {
            throw CoverageError(message: "iterator produced \(producedFrames) of \(reader.spool.frameCount) frames")
        }
        let digest = SHA256Hex.hex(hasher.finalize())
        guard digest == reader.spool.sha256 else {
            throw CoverageError(message: "replayed audio hash \(digest) differs from the prepared spool hash \(reader.spool.sha256); the spool changed after preparation")
        }
    }
}
