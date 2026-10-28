import AudioCore
import BenchmarkSupport
import CryptoKit
import Foundation
import Replay
import Testing

/// Chunks exactly as the consumer received them (samples kept, not summarized).
actor Delivered {
    var chunks: [AudioChunk] = []
    func add(_ chunk: AudioChunk) { chunks.append(chunk) }
}

/// Bitwise equality (distinguishes -0.0 and compares NaN payloads), not numeric equality.
func bitsEqual(_ a: some Sequence<Float>, _ b: some Sequence<Float>) -> Bool {
    a.map(\.bitPattern).elementsEqual(b.map(\.bitPattern))
}

func littleEndianSHA256(_ samples: [Float]) -> String {
    var hasher = SHA256()
    for sample in samples {
        withUnsafeBytes(of: sample.bitPattern.littleEndian) { hasher.update(bufferPointer: $0) }
    }
    return SHA256Hex.hex(hasher.finalize())
}

/// H2: what adapters receive is bit-for-bit the prepared spool, exactly once per sample.
struct AudioIntegrityTests {
    static let fixtures = ["mono16k_pcm16_final_partial", "mono44k1_pcm16_odd", "mono16k_pcm16_short_319",
                           "mono16k_pcm16_one_sample", "mono16k_pcm16_empty", "stereo48k_pcm24_tone1k",
                           "mono16k_f32_outside_unit"]
    static let modes: [(ReplayMode, ReplaySpeed?)] = [(.realtime, nil), (.accelerated, try! ReplaySpeed(numerator: 4, denominator: 1)),
                                                      (.step, nil)]

    private func run(_ spool: PCMSpool, _ mode: ReplayMode, _ speed: ReplaySpeed?, frame: Int64 = 320,
                     capacity: Int = 32, overflow: OverflowPolicy = .block,
                     slow: Bool = false) async throws -> (ReplayTrace, [AudioChunk]) {
        let delivered = Delivered()
        let trace = try await ReplayScheduler.run(
            spool: spool, configuration: try configuration(mode, frame: frame, speed: speed, capacity: capacity, overflow: overflow),
            clock: FakeRunClock()) { chunk, _ in
            await delivered.add(chunk)
            if slow { try await Task.sleep(nanoseconds: 1_000_000) }
        }
        return (trace, await delivered.chunks)
    }

    @Test(arguments: fixtures, [160, 320, 1280] as [Int64])
    func reconstructionMatchesSpoolBitForBit(_ name: String, _ frame: Int64) async throws {
        let spool = try preparedSpool(name)
        let truth = try PCMSpoolReader(spool).read(0, spool.frameCount)
        for (mode, speed) in Self.modes {
            let (trace, chunks) = try await run(spool, mode, speed, frame: frame)
            try trace.verifyCoverage(lossless: true)
            var rebuilt = [Float](repeating: .nan, count: Int(spool.frameCount))
            var writes = [Int](repeating: 0, count: Int(spool.frameCount))
            for chunk in chunks {
                for (offset, sample) in chunk.samples.values.enumerated() {
                    rebuilt[Int(chunk.startSample) + offset] = sample
                    writes[Int(chunk.startSample) + offset] += 1
                }
            }
            #expect(writes.allSatisfy { $0 == 1 }, "\(name) \(mode.rawValue) \(frame): every sample delivered exactly once")
            #expect(bitsEqual(rebuilt, truth), "\(name) \(mode.rawValue) \(frame): delivered audio differs from the spool")
            #expect(littleEndianSHA256(rebuilt) == spool.sha256, "reconstruction hash equals the prepared spool hash")
        }
    }

    @Test func partialFinalChunkIsExact() async throws {
        let spool = try preparedSpool("mono16k_pcm16_final_partial") // 16,100 frames
        let truth = try PCMSpoolReader(spool).read(0, spool.frameCount)
        for (mode, speed) in Self.modes {
            let (trace, chunks) = try await run(spool, mode, speed)
            let last = try #require(chunks.last)
            #expect(last.chunkIndex == 50 && last.startSample == 16_000 && last.endSample == 16_100)
            #expect(last.samples.count == 100)
            #expect(bitsEqual(last.samples.values, truth[16_000..<16_100]))
            let lastRecord = try #require(trace.records.last)
            if mode == .step { #expect(lastRecord.virtualDeadlineNS == 1_006_250_000) }
            if mode == .realtime { #expect(lastRecord.plannedDeadlineNS == trace.anchorNS + 1_006_250_000) }
        }
    }

    @Test func zeroLengthAndSingleSampleInputs() async throws {
        let empty = try preparedSpool("mono16k_pcm16_empty")
        #expect(empty.frameCount == 0)
        #expect(empty.sha256 == SHA256Hex.digest(Data()), "empty spool hashes as empty bytes")
        let one = try preparedSpool("mono16k_pcm16_one_sample")
        let oneTruth = try PCMSpoolReader(one).read(0, 1)
        for (mode, speed) in Self.modes {
            let (emptyTrace, emptyChunks) = try await run(empty, mode, speed)
            try emptyTrace.verifyCoverage(lossless: true)
            #expect(emptyChunks.isEmpty && emptyTrace.records.isEmpty, "\(mode.rawValue): no chunk for empty input")
            let (oneTrace, oneChunks) = try await run(one, mode, speed)
            try oneTrace.verifyCoverage(lossless: true)
            #expect(oneChunks.count == 1)
            #expect(oneChunks.first.map { $0.startSample == 0 && $0.endSample == 1 && bitsEqual($0.samples.values, oneTruth) } == true)
        }
    }

    /// Two consumers of the same chunk (the M3 ASR-then-diarization pattern): the first
    /// mutates its own copy; the second, and a final re-check of every retained chunk,
    /// still see exactly the spool. A backed-up queue keeps chunks alive while the
    /// producer keeps reading, so any buffer reuse by the producer would show up here.
    @Test func noMutationAfterEnqueue() async throws {
        let spool = try preparedSpool("stereo48k_pcm24_tone1k")
        let reader = try PCMSpoolReader(spool)
        let truth = try reader.read(0, spool.frameCount)
        let retained = Delivered()
        let trace = try await ReplayScheduler.run(
            spool: spool, configuration: try configuration(.realtime, capacity: 4, overflow: .block),
            clock: FakeRunClock()) { chunk, _ in
            var asrCopy = chunk.samples.values
            for index in asrCopy.indices { asrCopy[index] = -asrCopy[index] + 1 } // first "adapter" mutates its copy
            let range = Int(chunk.startSample)..<Int(chunk.endSample)
            #expect(bitsEqual(chunk.samples.values, truth[range]), "second consumer sees unmodified samples")
            await retained.add(chunk)
            try await Task.sleep(nanoseconds: 500_000)
        }
        try trace.verifyCoverage(lossless: true)
        #expect(trace.records.contains { $0.blocked }, "queue backed up, so chunks outlived later reads")
        for chunk in await retained.chunks {
            #expect(bitsEqual(chunk.samples.values, truth[Int(chunk.startSample)..<Int(chunk.endSample)]),
                    "chunk \(chunk.chunkIndex) changed after delivery")
        }
    }

    /// With drop_newest, admitted chunks are still bit-exact at their own ranges, and
    /// delivered ∪ dropped tiles the stream exactly once.
    @Test func droppedRunReconstructsAdmittedRanges() async throws {
        let spool = try preparedSpool("mono16k_pcm16_tone440_1s")
        let truth = try PCMSpoolReader(spool).read(0, spool.frameCount)
        let (trace, chunks) = try await run(spool, .realtime, nil, capacity: 2, overflow: .dropNewest, slow: true)
        try trace.verifyCoverage(lossless: false)
        #expect(trace.droppedSamples > 0)
        var coverage = [Int](repeating: 0, count: Int(spool.frameCount))
        for chunk in chunks {
            let range = Int(chunk.startSample)..<Int(chunk.endSample)
            #expect(bitsEqual(chunk.samples.values, truth[range]), "admitted chunk \(chunk.chunkIndex) is bit-exact")
            for index in range { coverage[index] += 1 }
        }
        for dropped in trace.droppedRanges {
            for index in Int(dropped.start)..<Int(dropped.end) { coverage[index] += 1 }
            #expect(!chunks.contains { $0.startSample < dropped.end && dropped.start < $0.endSample },
                    "no delivered chunk overlaps dropped range [\(dropped.start), \(dropped.end))")
        }
        #expect(coverage.allSatisfy { $0 == 1 }, "delivered ∪ dropped covers every sample exactly once")
        Evidence.write("M2-hardening/H2/drop-reconstruction.json", .object(JSONObject([
            ("total_frames", .int(spool.frameCount)), ("delivered_chunks", .int(Int64(chunks.count))),
            ("delivered_samples", .int(trace.consumedSamples)), ("dropped_samples", .int(trace.droppedSamples)),
            ("dropped_ranges", .array(trace.droppedRanges.map { $0.toJSON() })),
        ])))
    }

    /// A spool modified on disk after preparation must not replay as if it were the hashed audio.
    @Test(arguments: [ReplayMode.step, .realtime])
    func modifiedSpoolIsDetected(_ mode: ReplayMode) async throws {
        let spool = try preparedSpool("mono16k_pcm16_tone440_1s")
        let handle = try FileHandle(forWritingTo: spool.url)
        try handle.seek(toOffset: 4 * 8_000)
        try handle.write(contentsOf: Data(repeating: 0x7F, count: 4))
        try handle.close()
        do {
            _ = try await run(spool, mode, nil)
            Issue.record("tampered spool replayed without error")
        } catch let error as CoverageError {
            #expect(error.message.contains("spool changed after preparation"))
        }
    }
}
