import AdapterContracts
import AudioCore
import BenchmarkSupport
import Foundation
import MockAdapters
import Testing

/// A test-only ASR adapter written purely against the public contract
/// (V20 substitution check). It inspects the audio it receives — unlike the
/// scripted mocks — and emits one final per contiguous non-silent region.
/// It exists to prove a new adapter needs no runner or contract changes.
actor EnergyGateASR: ASRAdapter {
    nonisolated let adapterID = "test-energy-gate-asr"
    nonisolated var role: AdapterRole { .asr }

    private var lifecycle = AdapterLifecycle(adapterID: "test-energy-gate-asr")
    private var sink: (any AdapterEventSink)?
    private var openStart: Int64?
    private var lastEnd: Int64 = 0
    private var utterances: Int64 = 0

    func prepare(context: AdapterContext, sink: any AdapterEventSink) async throws -> AdapterCapabilities {
        try lifecycle.beginPrepare()
        self.sink = sink
        return try AdapterCapabilities(
            role: .asr, revision: "test", sampleRatesHz: [16_000], channels: 1, frameMultipleSamples: nil,
            incremental: true, emitsPartials: false, emitsFinals: true, transcriptGranularity: .utterances,
            requestedPlacement: .cpu, observedPlacement: .missing(.unavailable, source: "test", reason: "no backend"))
    }

    func consume(_ chunk: AudioChunk, context: ConsumeContext) async throws {
        try lifecycle.checkConsume(chunkIndex: chunk.chunkIndex)
        let loud = chunk.samples.values.contains { abs($0) > 0.01 }
        if loud, openStart == nil { openStart = chunk.startSample }
        if !loud, let start = openStart {
            try await close(start, chunk.startSample, .chunk(index: chunk.chunkIndex, invocationID: context.invocationID))
        }
        lastEnd = chunk.endSample
    }

    func flush(endOfStream: StreamEnd) async throws {
        try lifecycle.beginFlush()
        if let start = openStart { try await close(start, lastEnd, .flush(invocationID: endOfStream.invocationID)) }
    }

    func shutdown() async -> AdapterShutdownReport {
        _ = lifecycle.beginShutdown()
        sink = nil
        return .clean
    }

    private func close(_ start: Int64, _ end: Int64, _ cause: EventCause) async throws {
        openStart = nil
        try await sink?.emit(AdapterEvent(.transcript(utteranceID: "e\(utterances)", revision: 0, text: "voice",
                                                      isFinal: true),
                                          media: try SampleInterval(start: start, end: end), cause: cause))
        utterances += 1
    }
}

struct ExtensionSmokeTests {
    @Test func aSubstitutedASRRunsThroughThePublicContract() async throws {
        // Real decoded audio of the synthetic item: tones in [0, 128000), silence after.
        let prepared = try AudioPreparer.prepare(source: repoURL("datasets/fixtures/audio/synthetic/two-speaker-en.wav"),
                                                 sourceID: "two-speaker-en", targetRateHz: 16_000,
                                                 scratchDirectory: try makeScratch())
        let reader = try PCMSpoolReader(prepared.spool)
        let adapter: any ASRAdapter = EnergyGateASR()
        let spec = StreamSpec()
        let sink = CollectingSink(role: .asr, adapterID: adapter.adapterID, durationSamples: spec.duration)
        _ = try await adapter.prepare(context: context(.asr, spec, script: nil, delays: VirtualDelays()), sink: sink)
        for entry in try ChunkPlan(totalFrames: prepared.spool.frameCount, frameSamples: spec.frame) {
            let samples = try reader.read(entry.start, entry.end)
            let audio = try AudioChunk(runID: "test-run", streamID: "audio-0", sourceID: "two-speaker-en",
                                       chunkIndex: entry.index, sampleRateHz: 16_000, startSample: entry.start,
                                       endSample: entry.end, replayMode: .step, samples: OwnedMonoPCM(copying: samples))
            try await adapter.consume(audio, context: consumeContext(.asr, entry.index))
        }
        try await adapter.flush(endOfStream: StreamEnd(invocationID: "asr/flush", finalSample: spec.duration,
                                                       consumedSamples: spec.duration, droppedRanges: [], reason: .normal))
        #expect(await adapter.shutdown() == .clean)
        let events = await sink.events
        #expect(events.count == 1)
        #expect(events.first?.media == (try SampleInterval(start: 0, end: 128_000)),
                "the contiguous tone region becomes one final (both 'speakers' are loud)")
        Evidence.write("V20/extension-smoke.json", .array(events.map(view)))
    }

    @Test func rolesAreDistinctConformances() {
        let asr: any StreamingAdapter = MockASRAdapter()
        let diarization: any StreamingAdapter = MockDiarizationAdapter()
        #expect(asr is any ASRAdapter && !(asr is any DiarizationAdapter))
        #expect(diarization is any DiarizationAdapter && !(diarization is any ASRAdapter))
        #expect(asr.adapterID != diarization.adapterID)
    }
}
