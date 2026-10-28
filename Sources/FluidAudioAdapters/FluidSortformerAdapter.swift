import AdapterContracts
import BenchmarkSupport
@preconcurrency import CoreML
@preconcurrency import FluidAudio
import Foundation
import RealAdapterSupport

/// FluidAudio wrapper identity (pinned source, one-shot plan stage 1).
public enum FluidAudioAdapterIDs {
    public static let sourceRevision = "61d41b3ca04833d1cb80632c82ba401f117a01ef"
    public static let sortformer = "fluid-sortformer-v21-lowctx"
    public static let eou = "fluid-parakeet-eou-120m-320ms"
}

/// Parses the profile's requested compute units. Phase 1 profiles request `all`.
func computeUnits(_ profile: ModelProfile) throws -> MLComputeUnits {
    switch profile.computeUnits {
    case "all": return .all
    case "cpuAndNeuralEngine": return .cpuAndNeuralEngine
    case "cpuAndGPU": return .cpuAndGPU
    case "cpuOnly": return .cpuOnly
    default: throw ValidationError("$.compute_units", "unknown compute units \(profile.computeUnits)")
    }
}

public enum FluidSortformerAdapter {
    /// The streaming low-context v2.1 configuration with Fluid's own pass-through
    /// timeline post-processing, final-only output.
    public static func make(roots: Phase1Roots?) -> FinalTimelineDiarizationAdapter {
        FinalTimelineDiarizationAdapter(adapterID: FluidAudioAdapterIDs.sortformer,
                                        frameworkRevision: FluidAudioAdapterIDs.sourceRevision, roots: roots) { profile, url in
            try FluidSortformerBackend(profile: profile, modelURL: url)
        }
    }
}

/// Confines one `SortformerDiarizer`. During `push` it feeds Fluid's native streaming
/// state and discards the returned incremental updates (no tentative output is emitted).
/// `finish` calls `finalizeSession()` once, then reads the COMPLETE retained timeline
/// (segment storage enabled, unlimited retention): the finalize return value is only a delta.
actor FluidSortformerBackend: DiarizationBackend {
    private let profile: ModelProfile
    private let modelURL: URL
    private let config: SortformerConfig
    private let timelineConfig: DiarizerTimelineConfig
    private let units: MLComputeUnits
    private var diarizer: SortformerDiarizer?
    private var finished = false

    init(profile: ModelProfile, modelURL: URL) throws {
        self.profile = profile
        self.modelURL = modelURL
        guard try profile.stringSetting("preset") == "fastV2_1" else {
            throw ValidationError("$.settings.preset", "the Phase 1 Fluid Sortformer profile uses preset fastV2_1")
        }
        let config = SortformerConfig.fastV2_1
        // The frozen profile geometry must equal the preset this binary loads (no silent drift).
        let expected: [(String, Int)] = [
            ("chunk_len", config.chunkLen), ("left_context", config.chunkLeftContext),
            ("right_context", config.chunkRightContext), ("fifo_len", config.fifoLen),
            ("spkcache_len", config.spkcacheLen), ("spkcache_update_period", config.spkcacheUpdatePeriod),
            ("num_speakers", config.numSpeakers), ("subsampling_factor", config.subsamplingFactor),
            ("mel_stride", config.melStride), ("sample_rate", config.sampleRate),
        ]
        for (key, value) in expected where try profile.intSetting(key) != Int64(value) {
            throw ValidationError("$.settings.\(key)", "profile declares \(try profile.intSetting(key)); preset fastV2_1 has \(value)")
        }
        guard try profile.stringSetting("precision") == "\(config.precision)" else {
            throw ValidationError("$.settings.precision", "preset precision is \(config.precision)")
        }
        var timeline = DiarizerTimelineConfig.sortformerDefault
        timeline.storeSegments = true
        timeline.maxStoredFrames = nil
        // Compared in the SDK's Float precision (JSON numbers are Double).
        let expectedTimeline: [(String, Float)] = [
            ("onset_threshold", timeline.onsetThreshold), ("offset_threshold", timeline.offsetThreshold),
            ("onset_pad_frames", Float(timeline.onsetPadFrames)), ("offset_pad_frames", Float(timeline.offsetPadFrames)),
            ("min_frames_on", Float(timeline.minFramesOn)), ("min_frames_off", Float(timeline.minFramesOff)),
        ]
        for (key, value) in expectedTimeline where Float(try profile.numberSetting(key)) != value {
            throw ValidationError("$.settings.\(key)", "profile declares \(try profile.numberSetting(key)); Fluid default is \(value)")
        }
        self.config = config
        timelineConfig = timeline
        units = try computeUnits(profile)
    }

    private var samplesPerFrame: Int64 { Int64(config.subsamplingFactor * config.melStride) }

    /// Loads the compiled BNNS-fixed `v3/fp16` export directly, as FluidAudio's own Hub loader
    /// does (`initialize(mainModelPath:)` would try to compile an `.mlpackage`). FluidAudio only
    /// logs a geometry mismatch; this wrapper rejects it.
    func load() async throws {
        guard modelURL.pathExtension == "mlmodelc" else {
            throw ValidationError("$.model.load_path", "expected a compiled .mlmodelc (got \(modelURL.lastPathComponent))")
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = units
        let started = Date()
        let model = try MLModel(contentsOf: modelURL, configuration: configuration)
        let models = try SortformerModels(config: config, main: model,
                                          compilationDuration: Date().timeIntervalSince(started))
        // The EmbeddedConfig memberwise initializer is not public, so compare field by field.
        if let embedded = models.embeddedConfig {
            let actual = [embedded.chunkLen, embedded.chunkLeftContext, embedded.chunkRightContext, embedded.fifoLen,
                          embedded.spkcacheLen]
            let expected = [config.chunkLen, config.chunkLeftContext, config.chunkRightContext, config.fifoLen,
                            config.spkcacheLen]
            guard actual == expected else {
                throw ValidationError("fluid-sortformer",
                                      "model metadata geometry \(actual) differs from fastV2_1 \(expected) (C/L/R/FIFO/cache)")
            }
        }
        let diarizer = SortformerDiarizer(config: config, timelineConfig: timelineConfig)
        diarizer.initialize(models: models)
        self.diarizer = diarizer
    }

    func push(_ samples: [Float]) async throws {
        guard let diarizer, !finished else { throw ValidationError("fluid-sortformer", "push before load or after finish") }
        _ = try diarizer.process(samples: samples, sourceSampleRate: nil)
    }

    func finish() async throws -> [NativeSpeakerSegment] {
        guard let diarizer, !finished else { throw ValidationError("fluid-sortformer", "finish before load or twice") }
        finished = true
        _ = try diarizer.finalizeSession()
        let timeline = diarizer.timeline
        var segments: [NativeSpeakerSegment] = []
        for (_, speaker) in timeline.speakers.sorted(by: { $0.key < $1.key }) {
            guard speaker.tentativeSegments.isEmpty else {
                throw ValidationError("fluid-sortformer", "speaker \(speaker.index) still has tentative segments after finalize")
            }
            for segment in speaker.finalizedSegments {
                guard abs(segment.frameDurationSeconds * Float(Phase1Stream.sampleRateHz) - Float(samplesPerFrame)) < 0.5 else {
                    throw ValidationError("fluid-sortformer", "segment frame duration \(segment.frameDurationSeconds) s differs from \(samplesPerFrame) samples")
                }
                segments.append(NativeSpeakerSegment(
                    slot: segment.speakerIndex,
                    start: .frame(Int64(segment.startFrame), samplesPerFrame: samplesPerFrame),
                    end: .frame(Int64(segment.endFrame), samplesPerFrame: samplesPerFrame)))
            }
        }
        return segments
    }

    func release() async {
        diarizer?.cleanup()
        diarizer = nil
    }
}
