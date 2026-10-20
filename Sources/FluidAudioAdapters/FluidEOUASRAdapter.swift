import AdapterContracts
@preconcurrency import AVFoundation
import BenchmarkSupport
@preconcurrency import CoreML
@preconcurrency import FluidAudio
import Foundation
import RealAdapterSupport

public enum FluidEOUASRAdapter {
    /// English Parakeet EOU 120M, Fluid's 320 ms conversion, recording-granularity output.
    public static func make(roots: Phase1Roots?) -> RecordingTranscriptASRAdapter {
        RecordingTranscriptASRAdapter(adapterID: FluidAudioAdapterIDs.eou, frameworkRevision: FluidAudioAdapterIDs.sourceRevision,
                                      roots: roots) { profile, url in
            try FluidEOUBackend(profile: profile, modelDirectory: url)
        }
    }
}

/// Confines one `StreamingEouAsrManager`. Its partial callback carries the cumulative
/// recording text and fires synchronously inside `process`; the callback only posts into a
/// bounded mailbox, which is drained after the awaited call (no task per callback).
/// `process(audioBuffer:)` returns empty text by design; `finish()` returns the transcript.
actor FluidEOUBackend: StreamingASRBackend {
    static let mailboxCapacity = 4096

    nonisolated var accumulatorMode: RecordingTranscriptAccumulator.Mode { .cumulative }

    private let modelDirectory: URL
    private let chunkSize: StreamingChunkSize
    private let debounceMs: Int
    private let units: MLComputeUnits
    private let format: AVAudioFormat
    private let mailbox = CallbackMailbox<String>(capacity: FluidEOUBackend.mailboxCapacity)
    private var manager: StreamingEouAsrManager?

    init(profile: ModelProfile, modelDirectory: URL) throws {
        self.modelDirectory = modelDirectory
        guard try profile.stringSetting("chunk_size") == "320ms" else {
            throw ValidationError("$.settings.chunk_size", "the Phase 1 Fluid EOU profile uses the 320ms conversion")
        }
        chunkSize = .ms320
        for (key, value) in [("chunk_samples", chunkSize.chunkSamples), ("shift_samples", chunkSize.shiftSamples),
                             ("mel_frames", chunkSize.melFrames), ("pre_cache_size", chunkSize.preCacheSize)]
        where try profile.intSetting(key) != Int64(value) {
            throw ValidationError("$.settings.\(key)", "profile declares \(try profile.intSetting(key)); the 320ms mode has \(value)")
        }
        debounceMs = Int(try profile.intSetting("eou_debounce_ms"))
        guard try profile.stringSetting("decoder_path") == "reference_two_model" else {
            throw ValidationError("$.settings.decoder_path", "Phase 1 uses Fluid's default reference decoder+joint path")
        }
        if ProcessInfo.processInfo.environment["FLUID_EOU_FUSED"] == "1" {
            throw ValidationError("FLUID_EOU_FUSED", "must be unset: the profile freezes the reference decoder path")
        }
        units = try computeUnits(profile)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(Phase1Stream.sampleRateHz),
                                         channels: 1, interleaved: false) else {
            throw ValidationError("fluid-eou", "cannot create the 16 kHz mono Float32 format")
        }
        self.format = format
    }

    func load() async throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = units
        let manager = StreamingEouAsrManager(configuration: configuration, chunkSize: chunkSize, eouDebounceMs: debounceMs)
        // Local directory load only: this initializer never consults the network.
        try await manager.loadModels(from: modelDirectory)
        let mailbox = self.mailbox
        await manager.setPartialCallback { text in mailbox.post(text) }
        self.manager = manager
    }

    func push(_ samples: [Float]) async throws -> [ASRNativeUpdate] {
        guard let manager else { throw ValidationError("fluid-eou", "push before load") }
        let buffer = try makeBuffer(samples)
        let returned = try await manager.process(audioBuffer: buffer)
        guard returned.isEmpty else {
            throw ValidationError("fluid-eou", "process(audioBuffer:) returned text; the pinned API returns it only from finish()")
        }
        return try drain()
    }

    func finish() async throws -> [ASRNativeUpdate] {
        guard let manager else { throw ValidationError("fluid-eou", "finish before load") }
        let transcript = try await manager.finish()
        var updates = try drain()
        mailbox.close()
        updates.append(.cumulative(transcript))
        return updates
    }

    func release() async {
        mailbox.close()
        await manager?.cleanup()
        manager = nil
    }

    private func drain() throws -> [ASRNativeUpdate] {
        let (texts, overflowed) = mailbox.drain()
        guard !overflowed else {
            throw ValidationError("fluid-eou", "partial callback mailbox overflowed (capacity \(Self.mailboxCapacity))")
        }
        return texts.map(ASRNativeUpdate.cumulative)
    }

    private func makeBuffer(_ samples: [Float]) throws -> AVAudioPCMBuffer {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else {
            throw ValidationError("fluid-eou", "cannot allocate a \(samples.count)-frame buffer")
        }
        samples.withUnsafeBufferPointer { source in
            channel.update(from: source.baseAddress!, count: samples.count)
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        return buffer
    }
}
