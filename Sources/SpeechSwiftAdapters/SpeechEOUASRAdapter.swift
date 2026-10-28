import AdapterContracts
@preconcurrency import AudioCommon
import BenchmarkSupport
@preconcurrency import CoreML
import Foundation
@preconcurrency import ParakeetStreamingASR
import RealAdapterSupport

public enum SpeechEOUASRAdapter {
    /// English Parakeet EOU 120M, speech-swift's INT8 conversion, recording-granularity output.
    public static func make(roots: Phase1Roots?) -> RecordingTranscriptASRAdapter {
        RecordingTranscriptASRAdapter(adapterID: SpeechSwiftAdapterIDs.eou, frameworkRevision: SpeechSwiftAdapterIDs.sourceRevision,
                                      roots: roots) { profile, url in
            try SpeechEOUBackend(profile: profile, cacheDirectory: url)
        }
    }
}

/// Confines one `ParakeetStreamingASRModel` and its `StreamingSession`. `pushAudio` and
/// `finalize` return segment-indexed partial/final texts; the accumulator keeps finalized
/// segments (including legitimately repeated utterances) and replaces the current partial.
///
/// Loads with `cacheDir:` (the verified profile directory) and `offlineMode: true`, parameters
/// added by the owned copy's loader patch (DEC-079): only the local cache is consulted, and a
/// missing or incomplete cache fails the load instead of downloading or retrying the Hub.
actor SpeechEOUBackend: StreamingASRBackend {
    nonisolated var accumulatorMode: RecordingTranscriptAccumulator.Mode { .segmented }

    private let modelID: String
    private let cacheDirectory: URL
    private let expected: [(String, Int64)]
    private let debounceMs: Int
    private var model: ParakeetStreamingASRModel?
    private var session: StreamingSession?

    init(profile: ModelProfile, cacheDirectory: URL) throws {
        modelID = profile.modelRepository
        self.cacheDirectory = cacheDirectory.standardizedFileURL
        _ = try speechComputeUnits(profile)
        expected = try ["chunk_ms", "mel_frames", "pre_cache_size", "output_frames", "sample_rate"].map {
            ($0, try profile.intSetting($0))
        }
        debounceMs = Int(try profile.intSetting("eou_debounce_ms"))
    }

    func load() async throws {
        let model = try await ParakeetStreamingASRModel.fromPretrained(modelId: modelID, cacheDir: cacheDirectory,
                                                                       offlineMode: true)
        let streaming = model.config.streaming
        let actual: [String: Int64] = ["chunk_ms": Int64(streaming.chunkMs), "mel_frames": Int64(streaming.melFrames),
                                       "pre_cache_size": Int64(streaming.preCacheSize),
                                       "output_frames": Int64(streaming.outputFrames),
                                       "sample_rate": Int64(model.config.sampleRate)]
        for (key, value) in expected where actual[key] != value {
            throw ValidationError("$.settings.\(key)", "loaded config has \(actual[key].map(String.init) ?? "nil"); profile declares \(value)")
        }
        let session = try model.createSession()
        session.eouDebounceMs = debounceMs
        self.model = model
        self.session = session
    }

    func push(_ samples: [Float]) async throws -> [ASRNativeUpdate] {
        guard let session else { throw ValidationError("speech-eou", "push before load") }
        return try session.pushAudio(samples).map(Self.update)
    }

    func finish() async throws -> [ASRNativeUpdate] {
        guard let session else { throw ValidationError("speech-eou", "finish before load") }
        return try session.finalize().map(Self.update)
    }

    func release() async {
        session = nil
        model = nil
    }

    static func update(_ partial: ParakeetStreamingASRModel.PartialTranscript) -> ASRNativeUpdate {
        .segment(index: partial.segmentIndex, text: partial.text, isFinal: partial.isFinal)
    }
}
