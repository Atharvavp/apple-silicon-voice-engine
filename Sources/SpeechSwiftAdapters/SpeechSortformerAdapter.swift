import AdapterContracts
@preconcurrency import AudioCommon
import BenchmarkSupport
@preconcurrency import CoreML
import Foundation
import RealAdapterSupport
@preconcurrency import SpeechVAD

/// speech-swift wrapper identity (pinned source, one-shot plan stage 1).
public enum SpeechSwiftAdapterIDs {
    public static let sourceRevision = "3f58a58a8f867a4c87b97dbf4d6050d6a88ef665"
    public static let sortformer = "speech-sortformer-v21-streaming"
    public static let eou = "speech-parakeet-eou-120m-int8"
    /// speech-swift's loaders resolve compute units from this variable before their defaults.
    public static let computeUnitsVariable = "SPEECH_COREML_COMPUTE_UNITS"
}

/// The requested units must also be the explicit environment override, so every speech
/// loader (including ones with a hard-coded default) receives the same frozen request.
func speechComputeUnits(_ profile: ModelProfile) throws -> MLComputeUnits {
    guard let units = CoreMLComputeUnitsResolver.parse(profile.computeUnits) else {
        throw ValidationError("$.compute_units", "unknown compute units \(profile.computeUnits)")
    }
    let variable = SpeechSwiftAdapterIDs.computeUnitsVariable
    guard let raw = ProcessInfo.processInfo.environment[variable], CoreMLComputeUnitsResolver.parse(raw) == units else {
        throw ValidationError(variable, "must be set to \(profile.computeUnits) to match the profile request")
    }
    return units
}

public enum SpeechSortformerAdapter {
    /// The explicit `.streaming` preset (never the high-context default), final-only output.
    public static func make(roots: Phase1Roots?) -> FinalTimelineDiarizationAdapter {
        FinalTimelineDiarizationAdapter(adapterID: SpeechSwiftAdapterIDs.sortformer,
                                        frameworkRevision: SpeechSwiftAdapterIDs.sourceRevision, roots: roots) { profile, url in
            try SpeechSortformerBackend(profile: profile, cacheDirectory: url)
        }
    }
}

/// Confines one `SortformerStreamingSession`. `push(audio:)` advances native state; its
/// snapshots are discarded. `finish()` returns the complete final snapshot, which is the
/// only output. speech-swift compacts speaker IDs within each snapshot; the final
/// snapshot's IDs are used as slots.
actor SpeechSortformerBackend: DiarizationBackend {
    private let modelID: String
    private let cacheDirectory: URL
    private let config: SortformerConfig
    private let binarization: DiarizationConfig
    private let units: MLComputeUnits
    private var session: SortformerStreamingSession?
    private var finished = false

    init(profile: ModelProfile, cacheDirectory: URL) throws {
        modelID = profile.modelRepository
        self.cacheDirectory = cacheDirectory
        guard try profile.stringSetting("preset") == "streaming" else {
            throw ValidationError("$.settings.preset", "the Phase 1 speech Sortformer profile uses the .streaming preset")
        }
        let config = SortformerConfig.streaming
        let expected: [(String, Int)] = [
            ("chunk_len", Int(config.chunkLenSeconds)), ("left_context", Int(config.leftContextSeconds)),
            ("right_context", Int(config.rightContextSeconds)), ("fifo_len", config.fifoLen),
            ("spkcache_len", config.spkcacheLen), ("spkcache_update_period", config.spkcacheUpdatePeriod),
            ("num_speakers", config.maxSpeakers), ("subsampling_factor", config.subsamplingFactor),
            ("mel_stride", config.hopLength), ("sample_rate", config.sampleRate),
        ]
        for (key, value) in expected where try profile.intSetting(key) != Int64(value) {
            throw ValidationError("$.settings.\(key)", "profile declares \(try profile.intSetting(key)); preset .streaming has \(value)")
        }
        guard try profile.stringSetting("model_file") == config.coreMLModelFileName else {
            throw ValidationError("$.settings.model_file", "preset .streaming loads \(config.coreMLModelFileName)")
        }
        let binarization = DiarizationConfig.sortformer
        let expectedPost: [(String, Double)] = [
            ("onset_threshold", Double(binarization.onset)), ("offset_threshold", Double(binarization.offset)),
            ("min_speech_s", Double(binarization.minSpeechDuration)), ("min_silence_s", Double(binarization.minSilenceDuration)),
        ]
        for (key, value) in expectedPost where try profile.numberSetting(key) != value {
            throw ValidationError("$.settings.\(key)", "profile declares \(try profile.numberSetting(key)); speech default is \(value)")
        }
        self.config = config
        self.binarization = binarization
        units = try speechComputeUnits(profile)
    }

    func load() async throws {
        // offlineMode: only the verified local cache is consulted; no Hub access.
        let session = try await SortformerStreamingSession.fromPretrained(
            modelId: modelID, cacheDir: cacheDirectory, offlineMode: true, config: config, computeUnits: units)
        session.binarization = binarization
        self.session = session
    }

    func push(_ samples: [Float]) async throws {
        guard let session, !finished else { throw ValidationError("speech-sortformer", "push before load or after finish") }
        _ = try session.push(audio: samples)
    }

    func finish() async throws -> [NativeSpeakerSegment] {
        guard let session, !finished else { throw ValidationError("speech-sortformer", "finish before load or twice") }
        finished = true
        return try session.finish().segments.map { segment in
            NativeSpeakerSegment(slot: segment.speakerId, start: .seconds(Double(segment.startTime)),
                                 end: .seconds(Double(segment.endTime)))
        }
    }

    func release() async { session = nil }
}
