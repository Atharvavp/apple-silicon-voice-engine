import AdapterContracts
import AudioCore
import BenchmarkSupport
import Foundation

/// Built-in mock adapter IDs (config `adapters.*.id`).
public enum MockAdapterIDs {
    public static let asr = "mock-asr-scripted"
    public static let diarization = "mock-diar-scripted"
}

/// Deterministic scripted ASR mock. Emits the fixture script's transcript
/// partials/finals at their triggers; it never inspects sample values and
/// validates no recognition quality.
public actor MockASRAdapter: ASRAdapter {
    public nonisolated let adapterID: String
    public nonisolated var role: AdapterRole { .asr }

    private var lifecycle: AdapterLifecycle
    private var context: AdapterContext?
    private var sink: (any AdapterEventSink)?
    private var script: FixtureScript?
    private var player = ScriptPlayer<FixtureScript.TranscriptEntry>([])
    private var shutdownReport: AdapterShutdownReport?

    public init(adapterID: String = MockAdapterIDs.asr) {
        self.adapterID = adapterID
        lifecycle = AdapterLifecycle(adapterID: adapterID)
    }

    public func prepare(context: AdapterContext, sink: any AdapterEventSink) async throws -> AdapterCapabilities {
        try lifecycle.beginPrepare()
        guard let reference = context.fixtureScript else {
            throw AdapterError(.fixture, adapterID: adapterID, stage: .prepare, "the dataset item declares no fixture script")
        }
        let script = try FixtureScript.load(reference, adapterID: adapterID)
        try script.checkMatches(context, adapterID: adapterID)
        if script.fault(role: .asr, stage: .prepare) != nil {
            throw AdapterError(.injectedFault, adapterID: adapterID, stage: .prepare, "fixture-declared prepare fault")
        }
        self.context = context
        self.sink = sink
        self.script = script
        player = ScriptPlayer(script.asr.map { ($0.triggerSample, $0.range, $0) })
        return try mockCapabilities(role: .asr, revision: context.selection.revision, sampleRateHz: context.format.sampleRateHz)
    }

    public func consume(_ chunk: AudioChunk, context consume: ConsumeContext) async throws {
        try lifecycle.checkConsume(chunkIndex: chunk.chunkIndex)
        guard let context, let script else { throw AdapterError(.lifecycle, adapterID: adapterID, stage: .consume, "not prepared") }
        if script.fault(role: .asr, stage: .consume, chunkIndex: chunk.chunkIndex) != nil {
            throw AdapterError(.injectedFault, adapterID: adapterID, stage: .consume, chunkIndex: chunk.chunkIndex,
                               "fixture-declared consume fault")
        }
        player.consumed(try SampleInterval(start: chunk.startSample, end: chunk.endSample))
        if context.selection.delayMS > 0 { try await context.delays.delay(milliseconds: context.selection.delayMS) }
        try await emit(player.release(upTo: chunk.endSample),
                       cause: .chunk(index: chunk.chunkIndex, invocationID: consume.invocationID))
    }

    public func flush(endOfStream: StreamEnd) async throws {
        try lifecycle.beginFlush()
        guard let context, let script else { throw AdapterError(.lifecycle, adapterID: adapterID, stage: .flush, "not prepared") }
        if script.fault(role: .asr, stage: .flush) != nil {
            throw AdapterError(.injectedFault, adapterID: adapterID, stage: .flush, "fixture-declared flush fault")
        }
        if context.selection.delayMS > 0 { try await context.delays.delay(milliseconds: context.selection.delayMS) }
        try await emit(player.release(upTo: nil), cause: .flush(invocationID: endOfStream.invocationID))
    }

    public func shutdown() async -> AdapterShutdownReport {
        if let shutdownReport { return shutdownReport }
        _ = lifecycle.beginShutdown()
        let report = script?.fault(role: .asr, stage: .shutdown) != nil
            ? AdapterShutdownReport(status: .error, message: "fixture-declared shutdown fault", pendingTasks: 0)
            : .clean
        context = nil
        sink = nil
        shutdownReport = report
        return report
    }

    private func emit(_ released: [ScriptPlayer<FixtureScript.TranscriptEntry>.Release], cause: EventCause) async throws {
        guard let sink else { return }
        for item in released {
            switch item {
            case let .emit(entry, range):
                try await sink.emit(AdapterEvent(.transcript(utteranceID: entry.utteranceID, revision: entry.revision,
                                                             text: entry.text, isFinal: entry.isFinal),
                                                 media: range, cause: cause))
            case let .suppressed(entry, range, missing):
                try await sink.emit(missingAudioDiagnostic("transcript \(entry.utteranceID) revision \(entry.revision)",
                                                           range: range, missing: missing, cause: cause))
            }
        }
    }
}

/// Deterministic scripted diarization mock. Speaker labels come from the
/// script; this is not speaker recognition or attribution.
public actor MockDiarizationAdapter: DiarizationAdapter {
    public nonisolated let adapterID: String
    public nonisolated var role: AdapterRole { .diarization }

    private var lifecycle: AdapterLifecycle
    private var context: AdapterContext?
    private var sink: (any AdapterEventSink)?
    private var script: FixtureScript?
    private var player = ScriptPlayer<FixtureScript.SpeakerEntry>([])
    private var shutdownReport: AdapterShutdownReport?

    public init(adapterID: String = MockAdapterIDs.diarization) {
        self.adapterID = adapterID
        lifecycle = AdapterLifecycle(adapterID: adapterID)
    }

    public func prepare(context: AdapterContext, sink: any AdapterEventSink) async throws -> AdapterCapabilities {
        try lifecycle.beginPrepare()
        guard let reference = context.fixtureScript else {
            throw AdapterError(.fixture, adapterID: adapterID, stage: .prepare, "the dataset item declares no fixture script")
        }
        let script = try FixtureScript.load(reference, adapterID: adapterID)
        try script.checkMatches(context, adapterID: adapterID)
        if script.fault(role: .diarization, stage: .prepare) != nil {
            throw AdapterError(.injectedFault, adapterID: adapterID, stage: .prepare, "fixture-declared prepare fault")
        }
        self.context = context
        self.sink = sink
        self.script = script
        player = ScriptPlayer(try Self.perturbed(script, seed: context.seed).map { ($0.triggerSample, $0.range, $0) })
        return try mockCapabilities(role: .diarization, revision: context.selection.revision,
                                    sampleRateHz: context.format.sampleRateHz)
    }

    /// Applies the optional `splitmix64_v1` boundary perturbation: each segment
    /// shrinks by a seeded amount in `0...jitter` at each end (never below one
    /// sample), so causality (trigger >= end) still holds.
    static func perturbed(_ script: FixtureScript, seed: Int64) throws -> [FixtureScript.SpeakerEntry] {
        guard let jitter = script.perturbation?.speakerBoundaryJitterSamples, jitter > 0 else { return script.diarization }
        var generator = SplitMix64(seed: UInt64(seed))
        return try script.diarization.map { entry in
            let startShift = Int64(generator.uniform(upTo: UInt64(jitter)))
            let endShift = Int64(generator.uniform(upTo: UInt64(jitter)))
            var start = entry.range.start + startShift
            var end = entry.range.end - endShift
            if end <= start { (start, end) = (entry.range.start, entry.range.start + 1) }
            return FixtureScript.SpeakerEntry(ordinal: entry.ordinal, triggerSample: entry.triggerSample,
                                              segmentID: entry.segmentID, speakerID: entry.speakerID,
                                              range: try SampleInterval(start: start, end: end))
        }
    }

    public func consume(_ chunk: AudioChunk, context consume: ConsumeContext) async throws {
        try lifecycle.checkConsume(chunkIndex: chunk.chunkIndex)
        guard let context, let script else { throw AdapterError(.lifecycle, adapterID: adapterID, stage: .consume, "not prepared") }
        if script.fault(role: .diarization, stage: .consume, chunkIndex: chunk.chunkIndex) != nil {
            throw AdapterError(.injectedFault, adapterID: adapterID, stage: .consume, chunkIndex: chunk.chunkIndex,
                               "fixture-declared consume fault")
        }
        player.consumed(try SampleInterval(start: chunk.startSample, end: chunk.endSample))
        if context.selection.delayMS > 0 { try await context.delays.delay(milliseconds: context.selection.delayMS) }
        try await emit(player.release(upTo: chunk.endSample),
                       cause: .chunk(index: chunk.chunkIndex, invocationID: consume.invocationID))
    }

    public func flush(endOfStream: StreamEnd) async throws {
        try lifecycle.beginFlush()
        guard let context, let script else { throw AdapterError(.lifecycle, adapterID: adapterID, stage: .flush, "not prepared") }
        if script.fault(role: .diarization, stage: .flush) != nil {
            throw AdapterError(.injectedFault, adapterID: adapterID, stage: .flush, "fixture-declared flush fault")
        }
        if context.selection.delayMS > 0 { try await context.delays.delay(milliseconds: context.selection.delayMS) }
        try await emit(player.release(upTo: nil), cause: .flush(invocationID: endOfStream.invocationID))
    }

    public func shutdown() async -> AdapterShutdownReport {
        if let shutdownReport { return shutdownReport }
        _ = lifecycle.beginShutdown()
        let report = script?.fault(role: .diarization, stage: .shutdown) != nil
            ? AdapterShutdownReport(status: .error, message: "fixture-declared shutdown fault", pendingTasks: 0)
            : .clean
        context = nil
        sink = nil
        shutdownReport = report
        return report
    }

    private func emit(_ released: [ScriptPlayer<FixtureScript.SpeakerEntry>.Release], cause: EventCause) async throws {
        guard let sink else { return }
        for item in released {
            switch item {
            case let .emit(entry, range):
                try await sink.emit(AdapterEvent(.speakerSegment(segmentID: entry.segmentID, speakerID: entry.speakerID),
                                                 media: range, cause: cause))
            case let .suppressed(entry, range, missing):
                try await sink.emit(missingAudioDiagnostic("speaker segment \(entry.segmentID)", range: range,
                                                           missing: missing, cause: cause))
            }
        }
    }
}
