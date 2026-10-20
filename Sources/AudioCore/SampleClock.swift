import BenchmarkSupport
import Foundation

/// Exact sample-index <-> time mappings (plan D2 items 5, 7-11). All results
/// are integers computed with 128-bit intermediates; no floating seconds.
public enum SampleClock {
    public static let deadlineConvention = "end_of_frame_v1"

    /// Samples per frame; throws when `frame_ms` is not an integral sample count at `rate`.
    public static func frameSamples(sampleRateHz rate: Int64, frameMS: Int64) throws -> Int64 {
        guard ConfigLimits.frameSizesMS.contains(frameMS) else {
            throw ValidationError("frame_ms", "must be one of 10, 20, 40, 80 (got \(frameMS))")
        }
        guard rate > 0 else { throw ValidationError("sample_rate_hz", "must be positive") }
        let product = try CheckedMath.multiply(rate, frameMS)
        guard product % 1000 == 0 else {
            throw ValidationError("frame_ms", "\(frameMS) ms is not an integral number of samples at \(rate) Hz")
        }
        return product / 1000
    }

    /// Media deadline of a frame ending at `endSample` (end-of-frame availability):
    /// `floor(end * 1e9 / rate)` nanoseconds of media time.
    public static func mediaDeadlineNS(endSample: Int64, sampleRateHz rate: Int64) throws -> Int64 {
        try CheckedMath.mulDivFloor(endSample, 1_000_000_000, rate)
    }

    /// Accelerated replay offset from the anchor: `floor(end * 1e9 * den / (rate * num))`.
    public static func acceleratedOffsetNS(endSample: Int64, sampleRateHz rate: Int64, speed: ReplaySpeed) throws -> Int64 {
        let numerator = try CheckedMath.multiply(1_000_000_000, speed.denominator)
        let denominator = try CheckedMath.multiply(rate, speed.numerator)
        return try CheckedMath.mulDivFloor(endSample, numerator, denominator)
    }

    /// Converted length for sample-rate conversion (half-up endpoint rounding); same rate is identity.
    public static func convertedFrameCount(_ inputFrames: Int64, from sourceRate: Int64, to targetRate: Int64) throws -> Int64 {
        if sourceRate == targetRate { return inputFrames }
        return try CheckedMath.mulDivHalfUp(inputFrames, targetRate, sourceRate)
    }

    /// Maps an annotation boundary to another rate with the same half-up rule, clamped to `limit`.
    public static func mapBoundary(_ sample: Int64, from sourceRate: Int64, to targetRate: Int64, limit: Int64) throws -> Int64 {
        min(try convertedFrameCount(sample, from: sourceRate, to: targetRate), limit)
    }
}

/// Contiguous half-open chunk plan over `[0, totalFrames)` (plan D2 item 7).
public struct ChunkPlan: Sendable, Equatable, Sequence {
    public struct Entry: Sendable, Equatable {
        public let index: Int64
        public let start: Int64
        public let end: Int64
        public var count: Int64 { end - start }
    }

    public let totalFrames: Int64
    public let frameSamples: Int64

    public init(totalFrames: Int64, frameSamples: Int64) throws {
        guard totalFrames >= 0 else { throw ValidationError("total_frames", "must be nonnegative") }
        guard frameSamples > 0 else { throw ValidationError("frame_samples", "must be positive") }
        self.totalFrames = totalFrames
        self.frameSamples = frameSamples
    }

    public var chunkCount: Int64 { (totalFrames + frameSamples - 1) / frameSamples }

    public func makeIterator() -> AnyIterator<Entry> {
        var index: Int64 = 0
        return AnyIterator {
            let start = index * frameSamples
            guard start < totalFrames else { return nil }
            defer { index += 1 }
            return Entry(index: index, start: start, end: Swift.min(start + frameSamples, totalFrames))
        }
    }
}
