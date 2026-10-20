import AudioCore
import BenchmarkSupport
import Foundation
import Replay
import Testing

/// V04 (unit level): chunks tile [0, N) exactly once for every frame size.
struct ChunkContinuityTests {
    @Test(arguments: [0, 1, 159, 160, 161, 319, 320, 321, 16_000, 16_100] as [Int64],
          [160, 320, 640, 1280] as [Int64])
    func planTilesExactly(_ total: Int64, _ frame: Int64) throws {
        let entries = Array(try ChunkPlan(totalFrames: total, frameSamples: frame))
        #expect(Int64(entries.count) == (total + frame - 1) / frame)
        var cursor: Int64 = 0
        for (offset, entry) in entries.enumerated() {
            #expect(entry.index == Int64(offset))
            #expect(entry.start == cursor)
            #expect(entry.count > 0 && entry.count <= frame)
            if offset < entries.count - 1 { #expect(entry.count == frame) }
            cursor = entry.end
        }
        #expect(cursor == total)
    }

    @Test(arguments: ["mono16k_pcm16_final_partial", "mono44k1_pcm16_odd", "mono16k_pcm16_short_319",
                      "mono16k_pcm16_one_sample", "mono16k_pcm16_empty"])
    func iteratorReproducesSpoolExactly(_ name: String) throws {
        let prepared = try prepare(name)
        let all = try spoolSamples(prepared.spool)
        var iterator = try FrameIterator(
            spool: prepared.spool, frameSamples: 320,
            identity: .init(runID: "test", streamID: "audio-0", sourceID: name, mode: .step))
        var rebuilt: [Float] = []
        var expectedStart: Int64 = 0
        while let chunk = try iterator.nextChunk() {
            #expect(chunk.startSample == expectedStart)
            #expect(chunk.sampleCount == Int64(chunk.samples.count))
            rebuilt.append(contentsOf: chunk.samples.values)
            expectedStart = chunk.endSample
        }
        #expect(expectedStart == prepared.spool.frameCount)
        #expect(rebuilt == all)
    }

    @Test func chunkStorageIsImmutableValue() throws {
        let chunk = try AudioChunk(runID: "r", streamID: "s", sourceID: "x", chunkIndex: 0, sampleRateHz: 16_000,
                                   startSample: 0, endSample: 3, replayMode: .step,
                                   samples: OwnedMonoPCM(copying: [Float(0.1), 0.2, 0.3]))
        var copy = chunk.samples.values
        copy[0] = 99
        #expect(chunk.samples[0] == 0.1, "mutating a value copy must not affect the chunk")
        var source: [Float] = [1, 2, 3]
        let owned = OwnedMonoPCM(copying: source)
        source[1] = 42
        #expect(owned.values == [1, 2, 3], "construction copies its input")
    }

    @Test func invalidChunksAreRejected() {
        #expect(throws: ValidationError.self) {
            _ = try AudioChunk(runID: "r", streamID: "s", sourceID: "x", chunkIndex: 0, sampleRateHz: 16_000,
                               startSample: 5, endSample: 5, replayMode: .step, samples: OwnedMonoPCM(copying: [Float]()))
        }
        #expect(throws: ValidationError.self) {
            _ = try AudioChunk(runID: "r", streamID: "s", sourceID: "x", chunkIndex: 0, sampleRateHz: 16_000,
                               startSample: 0, endSample: 4, replayMode: .step, samples: OwnedMonoPCM(copying: [Float(1)]))
        }
    }
}
