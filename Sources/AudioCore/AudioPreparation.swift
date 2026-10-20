import AVFAudio
import BenchmarkSupport
import Foundation
import os

/// Source facts preserved verbatim (plan D2 item 3: never overwritten by the converted format).
public struct AudioSourceMetadata: Sendable, Equatable, JSONRepresentable {
    public let sourceID: String
    public let path: String
    public let sha256: String
    public let byteCount: Int64
    public let encoding: WAVSampleEncoding
    public let extensible: Bool
    public let sampleRateHz: Int64
    public let channels: Int
    public let frameCount: Int64

    public var durationSamples: Int64 { frameCount }

    public func toJSON() -> JSONValue {
        .object(JSONObject([
            ("source_id", .string(sourceID)), ("path", .string(path)), ("sha256", .string(sha256)),
            ("byte_count", .int(byteCount)), ("sample_format", .string(encoding.rawValue)),
            ("extensible", .bool(extensible)), ("source_sample_rate_hz", .int(sampleRateHz)),
            ("channels", .int(Int64(channels))), ("frame_count", .int(frameCount)),
            ("duration_samples", .int(durationSamples)),
        ]))
    }
}

/// Disclosed outcome of the endpoint rule; never silent (plan D2 item 5).
public enum EndpointStatus: String, Sendable, CaseIterable {
    case bypassed
    case exact
    case trimmedOneFrame = "trimmed_one_frame"
    case zeroExtendedOneFrame = "zero_extended_one_frame"

    public var isCorrection: Bool { self == .trimmedOneFrame || self == .zeroExtendedOneFrame }
}

/// What conversion actually did (plan D2 items 4-6), for `runtime_summary.json`.
public struct ConversionRecord: Sendable, Equatable, JSONRepresentable {
    public let policy: String
    public let downmixPolicy: String
    public let endpointPolicy: EndpointPolicy
    public let sourceFrames: Int64
    public let sourceRateHz: Int64
    public let targetRateHz: Int64
    public let intendedFrames: Int64
    public let nativeFrames: Int64
    public let trimmedTailFrames: Int64
    public let zeroExtendedTailFrames: Int64
    public let bypassed: Bool
    public let algorithm: String
    public let quality: String
    public let primeMethod: String
    public let primeLeadingFrames: Int64
    public let primeTrailingFrames: Int64
    public let convertedSHA256: String

    public var endpointStatus: EndpointStatus {
        if bypassed { return .bypassed }
        if trimmedTailFrames == 1 { return .trimmedOneFrame }
        if zeroExtendedTailFrames == 1 { return .zeroExtendedOneFrame }
        return .exact
    }

    /// Internal consistency of the record; violations mean the record (or the code
    /// that produced it) cannot be trusted.
    public func validate() throws {
        func fail(_ message: String) -> AudioError { AudioError(.conversionContract, "conversion_record", message) }
        guard (0...1).contains(trimmedTailFrames), (0...1).contains(zeroExtendedTailFrames),
              trimmedTailFrames + zeroExtendedTailFrames <= 1 else {
            throw fail("at most one tail frame may be trimmed or zero-extended")
        }
        guard nativeFrames - trimmedTailFrames + zeroExtendedTailFrames == intendedFrames else {
            throw fail("native \(nativeFrames) - trimmed \(trimmedTailFrames) + extended \(zeroExtendedTailFrames) != intended \(intendedFrames)")
        }
        guard intendedFrames == (try SampleClock.convertedFrameCount(sourceFrames, from: sourceRateHz, to: targetRateHz)) else {
            throw fail("intended frames \(intendedFrames) disagree with the half-up rule")
        }
        if bypassed {
            guard nativeFrames == intendedFrames, trimmedTailFrames == 0, zeroExtendedTailFrames == 0,
                  sourceRateHz == targetRateHz || sourceFrames == 0 else {
                throw fail("a bypassed conversion must be identity")
            }
        }
        if endpointPolicy == .strict, endpointStatus.isCorrection {
            throw fail("strict endpoint policy recorded a correction")
        }
    }

    /// Strict benchmark validation: the record must be consistent *and* carry no
    /// endpoint correction. Callers that accept corrections must disclose them instead.
    public func requireExactEndpoints() throws {
        try validate()
        guard !endpointStatus.isCorrection else {
            throw AudioError(.conversionContract, "conversion_record",
                             "endpoint correction \(endpointStatus.rawValue) (native \(nativeFrames), intended \(intendedFrames)) must be disclosed")
        }
    }

    public func toJSON() -> JSONValue {
        .object(JSONObject([
            ("policy", .string(policy)), ("downmix_policy", .string(downmixPolicy)),
            ("endpoint_policy", .string(endpointPolicy.rawValue)), ("endpoint_status", .string(endpointStatus.rawValue)),
            ("source_frames", .int(sourceFrames)), ("source_rate_hz", .int(sourceRateHz)),
            ("target_rate_hz", .int(targetRateHz)), ("intended_frames", .int(intendedFrames)),
            ("native_frames", .int(nativeFrames)), ("trimmed_tail_frames", .int(trimmedTailFrames)),
            ("zero_extended_tail_frames", .int(zeroExtendedTailFrames)), ("bypassed", .bool(bypassed)),
            ("algorithm", .string(algorithm)), ("quality", .string(quality)), ("prime_method", .string(primeMethod)),
            ("prime_leading_frames", .int(primeLeadingFrames)), ("prime_trailing_frames", .int(primeTrailingFrames)),
            ("converted_sha256", .string(convertedSHA256)),
        ]))
    }
}

public struct PreparedAudio: Sendable, Equatable {
    public let source: AudioSourceMetadata
    public let conversion: ConversionRecord
    public let spool: PCMSpool
}

/// Explicit downmix policy `arithmetic_mean_v1` (plan D2 item 2): mono passes
/// through; stereo is `Float((Double(L) + Double(R)) / 2)`. No normalization,
/// no clipping; >2 channels never reaches here (rejected by `WAVInspector`).
public enum MonoDownmixer {
    public static let policyID = "arithmetic_mean_v1"

    public static func mix(_ channels: UnsafePointer<UnsafeMutablePointer<Float>>, channelCount: Int, frames: Int) -> [Float] {
        switch channelCount {
        case 1:
            return Array(UnsafeBufferPointer(start: channels[0], count: frames))
        case 2:
            let left = channels[0]
            let right = channels[1]
            return (0..<frames).map { Float((Double(left[$0]) + Double(right[$0])) / 2) }
        default:
            preconditionFailure("WAVInspector admits only mono or stereo")
        }
    }
}

/// AVAudioFile decode to Float32 in fixed blocks, downmixed to mono per block.
public enum WAVDecoder {
    public static let blockFrames: AVAudioFrameCount = 4096

    /// Decodes the whole file, handing each mono block to `consume`. Returns frames decoded.
    @discardableResult
    public static func decode(_ url: URL, info: WAVInfo, consume: ([Float]) throws -> Void) throws -> Int64 {
        let path = url.path
        if info.frameCount == 0 { return 0 } // structurally valid empty WAV: nothing to decode
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            throw AudioError(.decodeFailed, path, "AVAudioFile could not open: \(error.localizedDescription)")
        }
        guard file.length == info.frameCount else {
            throw AudioError(.decodeFailed, path, "decoder reports \(file.length) frames; container has \(info.frameCount)")
        }
        guard Int(file.fileFormat.channelCount) == info.channels,
              file.fileFormat.sampleRate == Double(info.sampleRateHz) else {
            throw AudioError(.decodeFailed, path, "decoder format \(file.fileFormat) disagrees with the container")
        }
        let format = file.processingFormat
        guard format.commonFormat == .pcmFormatFloat32, !format.isInterleaved,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: blockFrames) else {
            throw AudioError(.decodeFailed, path, "unexpected processing format \(format)")
        }
        var decoded: Int64 = 0
        while decoded < info.frameCount {
            let want = AVAudioFrameCount(min(Int64(blockFrames), info.frameCount - decoded))
            do { try file.read(into: buffer, frameCount: want) } catch {
                throw AudioError(.decodeFailed, path, "read failed at frame \(decoded): \(error.localizedDescription)")
            }
            let got = Int(buffer.frameLength)
            guard got > 0, let channels = buffer.floatChannelData else {
                throw AudioError(.decodeFailed, path, "decoder made no progress at frame \(decoded)")
            }
            if info.encoding.isFloat {
                for channel in 0..<info.channels {
                    let samples = UnsafeBufferPointer(start: channels[channel], count: got)
                    if let bad = samples.firstIndex(where: { !$0.isFinite }) {
                        throw AudioError(.nonFiniteSample, path,
                                         "non-finite sample at frame \(decoded + Int64(bad)), channel \(channel)")
                    }
                }
            }
            try consume(MonoDownmixer.mix(UnsafePointer(channels), channelCount: info.channels, frames: got))
            decoded += Int64(got)
        }
        return decoded
    }
}

/// Streaming AVAudioConverter wrapper for policy `apple_normal_max_half_up_v1`.
///
/// Uses the block-based `convert(to:error:withInputFrom:)` overload (the
/// simple overload excludes sample-rate conversion), advances an input cursor
/// on every callback, signals end of stream once input is exhausted, and
/// drains the converter. A converter that stops making progress is an error.
public enum SampleRateConverter {
    public static let policyID = "apple_normal_max_half_up_v1"
    public static let algorithm = "normal"
    public static let quality = "max"
    public static let primeMethod = "normal"

    /// Feeds input to the converter's `@Sendable` input block. The SDK documents
    /// that `convert(to:error:withInputFrom:)` calls the block to pull input but
    /// not on which thread, so all mutable state sits behind a lock.
    private final class Feed: Sendable {
        private struct State {
            let reader: PCMSpoolReader
            var cursor: Int64 = 0
            var failure: Error?
        }

        private let format: AVAudioFormat
        private let blockFrames: Int64
        private let state: OSAllocatedUnfairLock<State>

        init(reader: PCMSpoolReader, format: AVAudioFormat, blockFrames: Int64) {
            self.format = format
            self.blockFrames = blockFrames
            state = OSAllocatedUnfairLock(uncheckedState: State(reader: reader))
        }

        var failure: Error? { state.withLockUnchecked { $0.failure } }

        func next(_ requested: AVAudioPacketCount, _ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
            state.withLockUnchecked { state in
                let total = state.reader.spool.frameCount
                guard state.cursor < total else {
                    status.pointee = .endOfStream
                    return nil
                }
                let count = min(Int64(max(requested, 1)), total - state.cursor, blockFrames)
                do {
                    let samples = try state.reader.read(state.cursor, state.cursor + count)
                    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
                          let destination = buffer.floatChannelData?[0] else {
                        throw AudioError(.conversionFailed, state.reader.spool.url.path, "cannot allocate converter input buffer")
                    }
                    samples.withUnsafeBufferPointer { destination.update(from: $0.baseAddress!, count: samples.count) }
                    buffer.frameLength = AVAudioFrameCount(count)
                    state.cursor += count
                    status.pointee = .haveData
                    return buffer
                } catch {
                    state.failure = error
                    status.pointee = .endOfStream
                    return nil
                }
            }
        }
    }

    public struct Result: Sendable {
        public let nativeFrames: Int64
        public let primeLeadingFrames: Int64
        public let primeTrailingFrames: Int64
    }

    /// Converts a mono source-rate spool, appending output to `writer`. Returns raw native counts.
    /// `inputBlockFrames` caps each input callback (tests use it to prove split-block equivalence).
    public static func convert(_ source: PCMSpool, to targetRate: Int64, writer: PCMSpoolWriter,
                               inputBlockFrames: Int64 = Int64(WAVDecoder.blockFrames)) throws -> Result {
        precondition(inputBlockFrames > 0)
        let path = source.url.path
        guard let inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(source.sampleRateHz),
                                              channels: 1, interleaved: false),
              let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(targetRate),
                                               channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat),
              let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: WAVDecoder.blockFrames) else {
            throw AudioError(.conversionFailed, path, "cannot create converter \(source.sampleRateHz) -> \(targetRate) Hz")
        }
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Normal
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        converter.primeMethod = .normal

        let feed = Feed(reader: try PCMSpoolReader(source), format: inputFormat, blockFrames: inputBlockFrames)
        var native: Int64 = 0
        var idleCalls = 0
        while true {
            output.frameLength = 0
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { requested, inputStatus in
                feed.next(requested, inputStatus)
            }
            if let failure = feed.failure { throw failure }
            if status == .error {
                throw AudioError(.conversionFailed, path, "AVAudioConverter error: \(conversionError?.localizedDescription ?? "unknown")")
            }
            let produced = Int(output.frameLength)
            if produced > 0, let samples = output.floatChannelData?[0] {
                try writer.append(UnsafeBufferPointer(start: samples, count: produced))
                native += Int64(produced)
                idleCalls = 0
            } else {
                idleCalls += 1
            }
            if status == .endOfStream { break }
            if idleCalls > 64 {
                throw AudioError(.conversionFailed, path, "converter made no progress (status \(status.rawValue))")
            }
        }
        return Result(nativeFrames: native, primeLeadingFrames: Int64(converter.primeInfo.leadingFrames),
                      primeTrailingFrames: Int64(converter.primeInfo.trailingFrames))
    }
}

/// Decode -> explicit mono -> (SRC | bypass) -> canonical spool, once per run, before replay.
public enum AudioPreparer {
    public static let sourceSpoolName = "source-mono.f32le"
    public static let convertedSpoolName = "converted.f32le"

    public static func prepare(source url: URL, sourceID: String, targetRateHz: Int64, scratchDirectory: URL,
                               endpointPolicy: EndpointPolicy = .allowOneFrame) throws -> PreparedAudio {
        let info = try WAVInspector.inspect(url)
        let (sourceDigest, sourceBytes) = try SHA256Hex.file(url)
        let metadata = AudioSourceMetadata(sourceID: sourceID, path: url.standardizedFileURL.path, sha256: sourceDigest,
                                           byteCount: sourceBytes, encoding: info.encoding, extensible: info.extensible,
                                           sampleRateHz: info.sampleRateHz, channels: info.channels,
                                           frameCount: info.frameCount)

        let sourceWriter = try PCMSpoolWriter(url: scratchDirectory.appendingPathComponent(sourceSpoolName))
        let decoded = try WAVDecoder.decode(url, info: info) { try sourceWriter.append($0) }
        let monoSpool = try sourceWriter.finish(sampleRateHz: info.sampleRateHz)
        guard decoded == info.frameCount, monoSpool.frameCount == info.frameCount else {
            throw AudioError(.decodeFailed, url.path, "decoded \(decoded) frames; container declares \(info.frameCount)")
        }
        let (spool, record) = try resample(monoSpool, to: targetRateHz,
                                           output: scratchDirectory.appendingPathComponent(convertedSpoolName),
                                           endpointPolicy: endpointPolicy)
        return PreparedAudio(source: metadata, conversion: record, spool: spool)
    }

    /// Converts (or bypasses) a mono source-rate spool into `output`, applying the
    /// endpoint policy. On success the source spool is consumed (moved or removed).
    public static func resample(_ monoSpool: PCMSpool, to targetRateHz: Int64, output: URL,
                                endpointPolicy: EndpointPolicy = .allowOneFrame,
                                inputBlockFrames: Int64 = Int64(WAVDecoder.blockFrames)) throws -> (PCMSpool, ConversionRecord) {
        let intended = try SampleClock.convertedFrameCount(monoSpool.frameCount, from: monoSpool.sampleRateHz,
                                                          to: targetRateHz)
        if monoSpool.sampleRateHz == targetRateHz || monoSpool.frameCount == 0 {
            do { try FileManager.default.moveItem(at: monoSpool.url, to: output) } catch {
                throw AudioError(.io, output.path, "cannot finalize spool: \(error.localizedDescription)")
            }
            let spool = PCMSpool(url: output, sampleRateHz: targetRateHz, frameCount: intended, sha256: monoSpool.sha256)
            let record = ConversionRecord(
                policy: SampleRateConverter.policyID, downmixPolicy: MonoDownmixer.policyID, endpointPolicy: endpointPolicy,
                sourceFrames: monoSpool.frameCount, sourceRateHz: monoSpool.sampleRateHz, targetRateHz: targetRateHz,
                intendedFrames: intended, nativeFrames: intended, trimmedTailFrames: 0, zeroExtendedTailFrames: 0,
                bypassed: true, algorithm: "bypass", quality: "bypass", primeMethod: "bypass",
                primeLeadingFrames: 0, primeTrailingFrames: 0, convertedSHA256: monoSpool.sha256)
            try record.validate()
            return (spool, record)
        }

        let writer = try PCMSpoolWriter(url: output)
        let result = try SampleRateConverter.convert(monoSpool, to: targetRateHz, writer: writer,
                                                     inputBlockFrames: inputBlockFrames)
        let difference = result.nativeFrames - intended
        var trimmed: Int64 = 0
        var extended: Int64 = 0
        switch (difference, endpointPolicy) {
        case (0, _):
            break
        case (1, .allowOneFrame):
            try writer.truncateTail(frames: 1)
            trimmed = 1
        case (-1, .allowOneFrame):
            try writer.append([Float(0)])
            extended = 1
        default:
            throw AudioError(.conversionContract, monoSpool.url.path,
                             "converter produced \(result.nativeFrames) frames; policy expects \(intended) "
                             + "(difference \(difference), endpoint policy \(endpointPolicy.rawValue))")
        }
        let spool = try writer.finish(sampleRateHz: targetRateHz)
        try? FileManager.default.removeItem(at: monoSpool.url)
        let record = ConversionRecord(
            policy: SampleRateConverter.policyID, downmixPolicy: MonoDownmixer.policyID, endpointPolicy: endpointPolicy,
            sourceFrames: monoSpool.frameCount, sourceRateHz: monoSpool.sampleRateHz, targetRateHz: targetRateHz,
            intendedFrames: intended, nativeFrames: result.nativeFrames, trimmedTailFrames: trimmed,
            zeroExtendedTailFrames: extended, bypassed: false, algorithm: SampleRateConverter.algorithm,
            quality: SampleRateConverter.quality, primeMethod: SampleRateConverter.primeMethod,
            primeLeadingFrames: result.primeLeadingFrames, primeTrailingFrames: result.primeTrailingFrames,
            convertedSHA256: spool.sha256)
        try record.validate()
        return (spool, record)
    }
}
