import BenchmarkSupport
import Foundation

/// Immutable owned mono Float32 samples (plan D1/D2 ownership rule).
///
/// Storage is a private `let` array copied at construction; callers get value
/// copies only, so no adapter can mutate another consumer's view and no
/// mutable pointer escapes. Zero-copy is deliberately not attempted.
public struct OwnedMonoPCM: Sendable, Equatable {
    private let storage: [Float]

    public init(copying samples: some Collection<Float>) {
        storage = Array(samples)
    }

    public init(copying buffer: UnsafeBufferPointer<Float>) {
        storage = Array(buffer)
    }

    public var count: Int { storage.count }
    public var isEmpty: Bool { storage.isEmpty }
    public subscript(index: Int) -> Float { storage[index] }

    /// A value copy; mutating the returned array never affects this chunk.
    public var values: [Float] { storage }
}

/// Logical audio chunk handed to adapters (plan D1). Timing observations live
/// in the separate delivery context, joined by `(runID, streamID, chunkIndex)`.
public struct AudioChunk: Sendable, Equatable {
    public let runID: String
    public let streamID: String
    public let sourceID: String
    public let chunkIndex: Int64
    public let sampleRateHz: Int64
    public let startSample: Int64
    public let endSample: Int64
    public let replayMode: ReplayMode
    public let samples: OwnedMonoPCM

    public init(runID: String, streamID: String, sourceID: String, chunkIndex: Int64, sampleRateHz: Int64,
                startSample: Int64, endSample: Int64, replayMode: ReplayMode, samples: OwnedMonoPCM) throws {
        guard chunkIndex >= 0, startSample >= 0, endSample > startSample else {
            throw ValidationError("chunk", "chunk \(chunkIndex) must be nonempty with 0 <= start < end (got [\(startSample), \(endSample)))")
        }
        guard Int64(samples.count) == endSample - startSample else {
            throw ValidationError("chunk", "chunk \(chunkIndex) holds \(samples.count) samples for range [\(startSample), \(endSample))")
        }
        guard sampleRateHz > 0 else { throw ValidationError("chunk", "sample rate must be positive") }
        self.runID = runID
        self.streamID = streamID
        self.sourceID = sourceID
        self.chunkIndex = chunkIndex
        self.sampleRateHz = sampleRateHz
        self.startSample = startSample
        self.endSample = endSample
        self.replayMode = replayMode
        self.samples = samples
    }

    public var sampleCount: Int64 { endSample - startSample }
}
