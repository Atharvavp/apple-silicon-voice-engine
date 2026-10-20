import AdapterContracts
import AudioCore
import BenchmarkSupport
import Foundation

/// The one stream format Phase 1 models accept: 16 kHz mono, prepared by AudioCore.
public enum Phase1Stream {
    public static let sampleRateHz: Int64 = 16_000
}

/// SDK-specific part of a diarization wrapper. Implementations are actors that confine
/// the SDK object; `finish` is called exactly once and returns the complete final timeline.
public protocol DiarizationBackend: Actor {
    /// Loads the already verified local model. Must not touch the network.
    func load() async throws
    /// Feeds contiguous 16 kHz mono samples into the native streaming state.
    func push(_ samples: [Float]) async throws
    /// Finalizes once at end of stream and returns every segment of the recording.
    func finish() async throws -> [NativeSpeakerSegment]
    /// Releases the model. Idempotent.
    func release() async
}

/// SDK-specific part of an ASR wrapper. Updates are returned only after every native
/// callback of the call has been drained (no detached callback tasks).
public protocol StreamingASRBackend: Actor {
    var accumulatorMode: RecordingTranscriptAccumulator.Mode { get }
    func load() async throws
    func push(_ samples: [Float]) async throws -> [ASRNativeUpdate]
    /// Flushes the native stream once; the returned updates complete the recording.
    func finish() async throws -> [ASRNativeUpdate]
    func release() async
}

public typealias DiarizationBackendFactory = @Sendable (ModelProfile, URL) throws -> any DiarizationBackend
public typealias ASRBackendFactory = @Sendable (ModelProfile, URL) throws -> any StreamingASRBackend

/// Shared preparation for real adapters: format, delay, profile and asset verification.
struct RealAdapterPreparation {
    let adapterID: String
    let role: AdapterRole
    let frameworkRevision: String
    let roots: Phase1Roots?

    func verify(_ context: AdapterContext) throws -> (ModelProfile, URL) {
        func fail(_ kind: AdapterError.Kind, _ message: String) -> AdapterError {
            AdapterError(kind, adapterID: adapterID, stage: .prepare, message)
        }
        guard context.role == role else { throw fail(.lifecycle, "configured as \(context.role.rawValue)") }
        guard context.format.sampleRateHz == Phase1Stream.sampleRateHz, context.format.channels == 1 else {
            throw fail(.incompatibleInput, "needs a 16000 Hz mono stream (got \(context.format.sampleRateHz) Hz, \(context.format.channels) ch)")
        }
        guard context.selection.delayMS == 0 else {
            throw fail(.incompatibleInput, "real adapters do not simulate delay; delay_ms must be 0")
        }
        guard context.fixtureScript == nil else {
            throw fail(.incompatibleInput, "real adapters take no fixture script; use a dataset item with fixture fields null")
        }
        guard let roots else {
            throw fail(.backend, "\(Phase1Roots.profilesVariable) and \(Phase1Roots.assetsVariable) must name absolute local roots")
        }
        let profile = try ModelProfileLoader.load(adapterID: adapterID, role: role, revision: context.selection.revision,
                                                  frameworkRevision: frameworkRevision, roots: roots)
        let loadURL = try ModelProfileLoader.verifyAssets(profile, roots: roots)
        return (profile, loadURL)
    }

    static func capabilities(role: AdapterRole, revision: String, emitsPartials: Bool) throws -> AdapterCapabilities {
        try AdapterCapabilities(
            role: role, revision: revision, sampleRatesHz: [Phase1Stream.sampleRateHz], channels: 1,
            frameMultipleSamples: nil, incremental: true, emitsPartials: emitsPartials, emitsFinals: true,
            transcriptGranularity: role == .asr ? .recording : nil, requestedPlacement: .unspecified,
            observedPlacement: .missing(.unavailable, source: "coreml_public_api",
                                        reason: "no_public_per_model_placement_observation"))
    }
}

/// Tracks that consumed audio is contiguous from sample 0 with no gaps or loss.
struct ContiguityGuard {
    private(set) var nextSample: Int64 = 0

    mutating func accept(_ chunk: AudioChunk, adapterID: String) throws {
        guard chunk.sampleRateHz == Phase1Stream.sampleRateHz else {
            throw AdapterError(.incompatibleInput, adapterID: adapterID, stage: .consume, chunkIndex: chunk.chunkIndex,
                               "chunk rate \(chunk.sampleRateHz) Hz")
        }
        guard chunk.startSample == nextSample else {
            throw AdapterError(.incompatibleInput, adapterID: adapterID, stage: .consume, chunkIndex: chunk.chunkIndex,
                               "audio is not contiguous: chunk starts at \(chunk.startSample), expected \(nextSample) (gap or dropped audio)")
        }
        nextSample = chunk.endSample
    }

    func checkComplete(_ end: StreamEnd, adapterID: String) throws {
        guard end.droppedRanges.isEmpty, end.consumedSamples == end.finalSample, nextSample == end.finalSample else {
            throw AdapterError(.incompatibleInput, adapterID: adapterID, stage: .flush,
                               "stream incomplete: consumed \(nextSample) of \(end.finalSample) samples, \(end.droppedRanges.count) dropped ranges")
        }
    }
}

/// Real diarization wrapper with final-only speaker output: native streaming state is fed
/// during `consume`, nothing is emitted until `flush`, which finalizes once and emits the
/// complete final timeline through the sink with `.flush` cause. No tentative, snapshot
/// or revised speaker events exist, so online speaker-label latency is not computable.
public actor FinalTimelineDiarizationAdapter: DiarizationAdapter {
    public nonisolated let adapterID: String
    public nonisolated var role: AdapterRole { .diarization }

    private let preparation: RealAdapterPreparation
    private let makeBackend: DiarizationBackendFactory
    private var lifecycle: AdapterLifecycle
    private var backend: (any DiarizationBackend)?
    private var sink: (any AdapterEventSink)?
    private var profile: ModelProfile?
    private var durationSamples: Int64 = 0
    private var contiguity = ContiguityGuard()
    private var shutdownReport: AdapterShutdownReport?
    public private(set) var lastProjection: TimelineProjection?

    public init(adapterID: String, frameworkRevision: String, roots: Phase1Roots?,
                makeBackend: @escaping DiarizationBackendFactory) {
        self.adapterID = adapterID
        preparation = RealAdapterPreparation(adapterID: adapterID, role: .diarization, frameworkRevision: frameworkRevision,
                                             roots: roots)
        self.makeBackend = makeBackend
        lifecycle = AdapterLifecycle(adapterID: adapterID)
    }

    public func prepare(context: AdapterContext, sink: any AdapterEventSink) async throws -> AdapterCapabilities {
        try lifecycle.beginPrepare()
        let (profile, loadURL) = try preparation.verify(context)
        guard profile.eosTailToleranceSamples != nil else {
            throw AdapterError(.backend, adapterID: adapterID, stage: .prepare, "profile lacks eos_tail_tolerance_samples")
        }
        let backend = try makeBackend(profile, loadURL)
        self.backend = backend
        try await backend.load()
        self.profile = profile
        self.sink = sink
        durationSamples = context.durationSamples
        return try RealAdapterPreparation.capabilities(role: .diarization, revision: profile.revision, emitsPartials: false)
    }

    public func consume(_ chunk: AudioChunk, context: ConsumeContext) async throws {
        try lifecycle.checkConsume(chunkIndex: chunk.chunkIndex)
        guard let backend else { throw AdapterError(.lifecycle, adapterID: adapterID, stage: .consume, "not prepared") }
        try contiguity.accept(chunk, adapterID: adapterID)
        do { try await backend.push(chunk.samples.values) } catch let error as AdapterError { throw error } catch {
            throw AdapterError(.backend, adapterID: adapterID, stage: .consume, chunkIndex: chunk.chunkIndex, "\(error)")
        }
    }

    public func flush(endOfStream: StreamEnd) async throws {
        try lifecycle.beginFlush()
        guard let backend, let sink, let profile, let tolerance = profile.eosTailToleranceSamples else {
            throw AdapterError(.lifecycle, adapterID: adapterID, stage: .flush, "not prepared")
        }
        guard endOfStream.reason == .normal else { return }
        try contiguity.checkComplete(endOfStream, adapterID: adapterID)
        let native: [NativeSpeakerSegment]
        do { native = try await backend.finish() } catch let error as AdapterError { throw error } catch {
            throw AdapterError(.backend, adapterID: adapterID, stage: .flush, "finalize failed: \(error)")
        }
        let projection: TimelineProjection
        do {
            projection = try FinalTimelineProjector.project(native, rate: Phase1Stream.sampleRateHz,
                                                            durationSamples: durationSamples, tailToleranceSamples: tolerance)
        } catch {
            throw AdapterError(.contract, adapterID: adapterID, stage: .flush, "\(error)")
        }
        lastProjection = projection
        let cause = EventCause.flush(invocationID: endOfStream.invocationID)
        for segment in projection.segments {
            try await sink.emit(AdapterEvent(.speakerSegment(segmentID: segment.segmentID, speakerID: segment.speakerID),
                                             media: segment.interval, cause: cause))
        }
    }

    public func shutdown() async -> AdapterShutdownReport {
        if let shutdownReport { return shutdownReport }
        _ = lifecycle.beginShutdown()
        await backend?.release()
        backend = nil
        sink = nil
        shutdownReport = .clean
        return .clean
    }
}

/// Real streaming ASR wrapper at recording granularity: genuine cumulative partials
/// (increasing revisions of one recording utterance) and exactly one untimed final at
/// flush. No word timestamps are invented, so first-word latency stays not computable.
public actor RecordingTranscriptASRAdapter: ASRAdapter {
    public static let utteranceID = "recording"

    public nonisolated let adapterID: String
    public nonisolated var role: AdapterRole { .asr }

    private let preparation: RealAdapterPreparation
    private let makeBackend: ASRBackendFactory
    private var lifecycle: AdapterLifecycle
    private var backend: (any StreamingASRBackend)?
    private var sink: (any AdapterEventSink)?
    private var accumulator = RecordingTranscriptAccumulator(mode: .cumulative)
    private var revision: Int64 = 0
    private var contiguity = ContiguityGuard()
    private var shutdownReport: AdapterShutdownReport?

    public init(adapterID: String, frameworkRevision: String, roots: Phase1Roots?, makeBackend: @escaping ASRBackendFactory) {
        self.adapterID = adapterID
        preparation = RealAdapterPreparation(adapterID: adapterID, role: .asr, frameworkRevision: frameworkRevision, roots: roots)
        self.makeBackend = makeBackend
        lifecycle = AdapterLifecycle(adapterID: adapterID)
    }

    public func prepare(context: AdapterContext, sink: any AdapterEventSink) async throws -> AdapterCapabilities {
        try lifecycle.beginPrepare()
        let (profile, loadURL) = try preparation.verify(context)
        let backend = try makeBackend(profile, loadURL)
        self.backend = backend
        try await backend.load()
        accumulator = RecordingTranscriptAccumulator(mode: await backend.accumulatorMode)
        self.sink = sink
        return try RealAdapterPreparation.capabilities(role: .asr, revision: profile.revision, emitsPartials: true)
    }

    public func consume(_ chunk: AudioChunk, context: ConsumeContext) async throws {
        try lifecycle.checkConsume(chunkIndex: chunk.chunkIndex)
        guard let backend else { throw AdapterError(.lifecycle, adapterID: adapterID, stage: .consume, "not prepared") }
        try contiguity.accept(chunk, adapterID: adapterID)
        let updates: [ASRNativeUpdate]
        do { updates = try await backend.push(chunk.samples.values) } catch let error as AdapterError { throw error } catch {
            throw AdapterError(.backend, adapterID: adapterID, stage: .consume, chunkIndex: chunk.chunkIndex, "\(error)")
        }
        try await emitPartials(updates, cause: .chunk(index: chunk.chunkIndex, invocationID: context.invocationID),
                               stage: .consume, chunkIndex: chunk.chunkIndex)
    }

    public func flush(endOfStream: StreamEnd) async throws {
        try lifecycle.beginFlush()
        guard let backend, let sink else { throw AdapterError(.lifecycle, adapterID: adapterID, stage: .flush, "not prepared") }
        guard endOfStream.reason == .normal else { return }
        try contiguity.checkComplete(endOfStream, adapterID: adapterID)
        let cause = EventCause.flush(invocationID: endOfStream.invocationID)
        let updates: [ASRNativeUpdate]
        do { updates = try await backend.finish() } catch let error as AdapterError { throw error } catch {
            throw AdapterError(.backend, adapterID: adapterID, stage: .flush, "finalize failed: \(error)")
        }
        try await emitPartials(updates, cause: cause, stage: .flush, chunkIndex: nil)
        revision += 1
        try await sink.emit(AdapterEvent(.transcript(utteranceID: Self.utteranceID, revision: revision,
                                                     text: accumulator.finalizedText(), isFinal: true),
                                         media: nil, cause: cause))
    }

    public func shutdown() async -> AdapterShutdownReport {
        if let shutdownReport { return shutdownReport }
        _ = lifecycle.beginShutdown()
        await backend?.release()
        backend = nil
        sink = nil
        shutdownReport = .clean
        return .clean
    }

    private func emitPartials(_ updates: [ASRNativeUpdate], cause: EventCause, stage: AdapterStage,
                              chunkIndex: Int64?) async throws {
        guard let sink else { return }
        for update in updates {
            let changed: String?
            do { changed = try accumulator.apply(update) } catch {
                throw AdapterError(.backend, adapterID: adapterID, stage: stage, chunkIndex: chunkIndex, "\(error)")
            }
            guard let text = changed else { continue }
            revision += 1
            try await sink.emit(AdapterEvent(.transcript(utteranceID: Self.utteranceID, revision: revision, text: text,
                                                         isFinal: false),
                                             media: nil, cause: cause))
        }
    }
}
