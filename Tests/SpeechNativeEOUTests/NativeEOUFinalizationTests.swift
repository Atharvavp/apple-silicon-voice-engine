// Model-free checks of the unmodified speech-swift `StreamingSession` (A2's native EOU
// path), Phase 1 follow-up Step 0 / review finding F04. The real session, mel front end,
// RNNT greedy loop, EOU debounce and `finalize()` run unchanged; only the three MLModels
// are stubs whose outputs are scripted per (encoder chunk, encoder frame). No Core ML
// model is loaded and no inference happens. Native updates are then projected through
// the harness's own A2 mapping (`SpeechEOUBackend.update`) and recording accumulator,
// exactly as `RecordingTranscriptASRAdapter.consume/flush` do.
//
// Tests that assert *correct* behaviour the SDK does not provide are wrapped in
// `withKnownIssue`; the neighbouring characterization expectations pin what the original
// A2 configuration actually does, so a behaviour change (fix or regression) fails loudly.

import CoreML
import Foundation
@testable import ParakeetStreamingASR
import RealAdapterSupport
@testable import SpeechSwiftAdapters
import Testing

// MARK: - Stub models

/// An MLModel whose prediction is a Swift closure. No compiled model is involved.
final class StubModel: MLModel, @unchecked Sendable {
    private let body: (MLFeatureProvider) throws -> MLFeatureProvider

    init(_ body: @escaping (MLFeatureProvider) throws -> MLFeatureProvider) {
        self.body = body
        super.init()
    }

    override func prediction(from input: MLFeatureProvider) throws -> MLFeatureProvider { try body(input) }

    override func prediction(from input: MLFeatureProvider, options: MLPredictionOptions) throws -> MLFeatureProvider {
        try body(input)
    }
}

/// A2's real streaming geometry: the INT8 asset's `config.json` and the frozen A2 profile
/// settings (chunk_ms 320, mel_frames 64, output_frames 4, pre_cache_size 9, 16 kHz).
let a2Config = try! JSONDecoder().decode(ParakeetEOUConfig.self, from: Data(#"""
{"numMelBins":128,"sampleRate":16000,"nFFT":512,"hopLength":160,"winLength":400,"preEmphasis":0.97,
 "encoderHidden":512,"encoderLayers":17,"subsamplingFactor":8,"attentionContext":70,"convCacheSize":8,
 "decoderHidden":640,"decoderLayers":1,"vocabSize":1026,"blankTokenId":1026,"eouTokenId":1024,"eobTokenId":1025,
 "streaming":{"chunkMs":320,"melFrames":64,"preCacheSize":9,"outputFrames":4}}
"""#.utf8))
let a2DebounceMs = 1280 // frozen A2 profile `eou_debounce_ms`

enum Tok {
    static let yeah = 10, so = 11, okay = 12
    static let eou = a2Config.eouTokenId
    static let vocabulary = ParakeetEOUVocabulary(idToToken: [yeah: "▁yeah", so: "▁so", okay: "▁okay"])
}

/// Scripted encoder/decoder/joint. Each encoder call is one native chunk; its output frames
/// carry (chunk, frame) so the joint can return the scripted argmax sequence for that frame
/// (then blank). `script[chunk][frame]` lists non-blank ids; `Tok.eou` ends the frame.
final class ScriptedEOUModels: @unchecked Sendable {
    let config: ParakeetEOUConfig
    let script: [Int: [Int: [Int]]]
    private(set) var encoderCalls = 0
    private(set) var jointFrames: [(chunk: Int, frame: Int)] = []
    private var cursorFrame: (Int, Int)?
    private var cursor = 0

    init(config: ParakeetEOUConfig = a2Config, script: [Int: [Int: [Int]]]) {
        self.config = config
        self.script = script
    }

    /// Encoder output frames per chunk (64 mel frames / subsampling 8); only the first
    /// `outputFrames` are decoded by the session, the rest are look-ahead.
    var encoderFrames: Int { config.streaming.melFrames / config.subsamplingFactor }

    lazy var encoder = StubModel { [unowned self] input in
        let chunk = encoderCalls
        encoderCalls += 1
        let hidden = config.encoderHidden
        let encoded = try MLMultiArray(shape: [1, encoderFrames as NSNumber, hidden as NSNumber], dataType: .float16)
        let values = encoded.dataPointer.assumingMemoryBound(to: Float16.self)
        values.initialize(repeating: 0, count: encoderFrames * hidden)
        for frame in 0..<encoderFrames {
            values[frame * hidden] = Float16(chunk % 1024)
            values[frame * hidden + 1] = Float16(chunk / 1024)
            values[frame * hidden + 2] = Float16(frame)
        }
        let length = try MLMultiArray(shape: [1], dataType: .int32)
        length[0] = NSNumber(value: Int32(encoderFrames))
        var outputs: [String: Any] = ["encoded_output": encoded, "encoded_length": length]
        for (output, inputName) in [("new_pre_cache", "pre_cache"), ("new_cache_last_channel", "cache_last_channel"),
                                    ("new_cache_last_time", "cache_last_time"),
                                    ("new_cache_last_channel_len", "cache_last_channel_len")] {
            outputs[output] = input.featureValue(for: inputName)!
        }
        return try MLDictionaryFeatureProvider(dictionary: outputs)
    }

    lazy var decoder = StubModel { [unowned self] _ in
        let shape = [config.decoderLayers, 1, config.decoderHidden] as [NSNumber]
        var outputs: [String: Any] = [:]
        for name in ["decoder_output", "h_out", "c_out"] {
            let array = try MLMultiArray(shape: shape, dataType: .float16)
            array.dataPointer.assumingMemoryBound(to: Float16.self).initialize(repeating: 0, count: array.count)
            outputs[name] = array
        }
        return try MLDictionaryFeatureProvider(dictionary: outputs)
    }

    lazy var joint = StubModel { [unowned self] input in
        let slice = input.featureValue(for: "encoder_output")!.multiArrayValue!
        let e = slice.dataPointer.assumingMemoryBound(to: Float.self)
        let chunk = Int(e[0]) + 1024 * Int(e[1]), frame = Int(e[2])
        if cursorFrame.map({ $0 != (chunk, frame) }) ?? true {
            cursorFrame = (chunk, frame)
            cursor = 0
            jointFrames.append((chunk, frame))
        }
        let ids = script[chunk]?[frame] ?? []
        let id = cursor < ids.count ? ids[cursor] : config.blankTokenId
        cursor += 1
        let classes = config.vocabSize + 1
        let logits = try MLMultiArray(shape: [1, 1, 1, classes as NSNumber], dataType: .float16)
        let values = logits.dataPointer.assumingMemoryBound(to: Float16.self)
        values.initialize(repeating: 0, count: classes)
        values[id] = 10
        return try MLDictionaryFeatureProvider(dictionary: ["logits": logits])
    }

    func makeSession() throws -> StreamingSession {
        let session = try StreamingSession(config: config, encoder: encoder, decoder: decoder, joint: joint,
                                           vocabulary: Tok.vocabulary,
                                           melPreprocessor: StreamingMelPreprocessor(config: config))
        session.eouDebounceMs = a2DebounceMs
        return session
    }
}

// MARK: - Driver

/// Native chunk geometry: chunk `c` is processed once `chunkSamples + c * shiftSamples` have
/// been pushed; `finalize()` then processes the remainder as one zero-padded trailing chunk.
let chunkSamples = a2Config.streaming.melFrames * a2Config.hopLength                                   // 10240
let shiftSamples = a2Config.streaming.outputFrames * a2Config.subsamplingFactor * a2Config.hopLength    // 5120
let pushSamples = 320 // the harness's 20 ms frames

/// Total samples such that regular chunks 0...lastRegular run and chunk lastRegular+1 is
/// the trailing chunk processed inside `finalize()`.
func streamSamples(lastRegularChunk: Int) -> Int { chunkSamples + lastRegularChunk * shiftSamples + shiftSamples / 2 }

struct Projected {
    var native: [ParakeetStreamingASRModel.PartialTranscript] = []
    var nativeFinals: [String] { native.filter(\.isFinal).map(\.text) }
    /// Recording partial texts in emission order, as `RecordingTranscriptASRAdapter` emits them.
    var recordingPartials: [String] = []
    /// The single recording final emitted at flush (finalized segments only).
    var recordingFinal = ""
    /// Text of a native segment still open (never finalized) when the stream ended.
    var openAtFlush: String?
    var encoderCalls = 0
}

/// Runs the scripted session over `total` zero samples in 320-sample pushes, then finalizes.
/// Mirrors `SpeechEOUBackend.push/finish` (`pushAudio`/`finalize` mapped by `update`) and the
/// adapter's accumulator handling; A2's backend uses the segmented accumulator mode.
func run(_ models: ScriptedEOUModels, total: Int) throws -> Projected {
    precondition(total % pushSamples == 0)
    let session = try models.makeSession()
    var out = Projected()
    var accumulator = RecordingTranscriptAccumulator(mode: .segmented)
    func apply(_ partials: [ParakeetStreamingASRModel.PartialTranscript]) throws {
        for partial in partials {
            out.native.append(partial)
            if let changed = try accumulator.apply(SpeechEOUBackend.update(partial)) { out.recordingPartials.append(changed) }
        }
    }
    let frame = [Float](repeating: 0, count: pushSamples)
    for _ in 0..<(total / pushSamples) { try apply(try session.pushAudio(frame)) }
    try apply(try session.finalize())
    out.recordingFinal = accumulator.finalizedText()
    if accumulator.openSegmentIndex != nil {
        out.openAtFlush = String(accumulator.currentText().dropFirst(out.recordingFinal.count))
            .trimmingCharacters(in: .whitespaces)
    }
    out.encoderCalls = models.encoderCalls
    return out
}

/// Every recording partial extends the previous one (the invariant the saved-trace audit
/// `scripts/phase1_followup/asr_rollback_audit.py` checks); returns the violating pairs.
func rollbacks(_ partials: [String]) -> [(String, String)] {
    zip(partials, partials.dropFirst()).filter { !$0.1.hasPrefix($0.0) }
}

// MARK: - F04a: consecutive genuine utterances with identical text

struct RepeatedUtteranceTests {
    /// Three genuine utterances, each closed by a debounced EOU: chunk 1 / 6 / 11 decode the
    /// words; EOU in the next three chunks confirms (the debounce counts each 640 ms chunk
    /// buffer, so the third consecutive EOU chunk reaches 1280 ms); one blank chunk between.
    static func script(_ words: [Int]) -> [Int: [Int: [Int]]] {
        var script: [Int: [Int: [Int]]] = [:]
        for (n, word) in words.enumerated() {
            let start = 1 + 5 * n
            script[start] = [0: [word]]
            for eouChunk in (start + 1)...(start + 3) { script[eouChunk] = [0: [Tok.eou]] }
        }
        return script
    }

    @Test func distinctUtterancesAreAllFinalized() throws {
        let out = try run(ScriptedEOUModels(script: Self.script([Tok.yeah, Tok.okay, Tok.so])),
                          total: streamSamples(lastRegularChunk: 16))
        #expect(out.nativeFinals == ["yeah", "okay", "so"])
        #expect(out.native.filter(\.isFinal).map(\.segmentIndex) == [0, 1, 2])
        #expect(out.recordingFinal == "yeah okay so")
        #expect(rollbacks(out.recordingPartials).isEmpty && out.openAtFlush == nil)
    }

    @Test func identicalConsecutiveUtteranceIsSuppressedByNativeSession() throws {
        let out = try run(ScriptedEOUModels(script: Self.script([Tok.yeah, Tok.yeah, Tok.so])),
                          total: streamSamples(lastRegularChunk: 16))
        // Characterization of the original A2 SDK path (StreamingSession.swift:374-381): the
        // second "yeah" advances eouTokenOffset/segmentIndex, then is dropped because its text
        // equals the previous final. Its tokens are consumed and never re-emitted.
        #expect(out.nativeFinals == ["yeah", "so"])
        #expect(out.native.filter(\.isFinal).map(\.segmentIndex) == [0, 2], "segment 1 is skipped")
        #expect(out.recordingFinal == "yeah so")
        // Signature in the emitted recording partials: the open "yeah" vanishes when the next
        // segment opens. The saved-trace audit detects exactly this pattern.
        #expect(out.recordingPartials == ["yeah", "yeah yeah", "yeah so"])
        #expect(rollbacks(out.recordingPartials).map(\.1) == ["yeah so"])
        withKnownIssue("F04a: speech-swift suppresses a legitimate final whose text equals the previous final") {
            #expect(out.nativeFinals == ["yeah", "yeah", "so"])
            #expect(out.recordingFinal == "yeah yeah so")
        }
    }

    @Test func suppressionAlsoSpansASilentEOUBoundary() throws {
        // "yeah" (final) … a silence-only EOU (chunks 6-8, the empty-text path, which does not
        // clear the remembered final text) … "yeah" again (chunk 10): still suppressed.
        var script = Self.script([Tok.yeah])
        for c in 6...8 { script[c] = [0: [Tok.eou]] }
        script[10] = [0: [Tok.yeah]]
        for c in 11...13 { script[c] = [0: [Tok.eou]] }
        let out = try run(ScriptedEOUModels(script: script), total: streamSamples(lastRegularChunk: 16))
        #expect(out.nativeFinals == ["yeah"])
        #expect(out.recordingFinal == "yeah")
        withKnownIssue("F04a across an empty EOU segment") {
            #expect(out.nativeFinals == ["yeah", "yeah"])
        }
    }
}

// MARK: - F04b: EOU confirmed inside finalize()'s padded trailing chunk

struct TrailingChunkFinalizationTests {
    /// "okay" in chunk 1, EOU candidates in chunks 2 and 3; regular chunks end at 3, so the
    /// third EOU chunk (which reaches the debounce) is the trailing chunk inside `finalize()`.
    static let script: [Int: [Int: [Int]]] = [1: [0: [Tok.okay]], 2: [0: [Tok.eou]], 3: [0: [Tok.eou]], 4: [0: [Tok.eou]]]

    @Test func pendingSegmentIsFinalizedWhenTrailingChunkDoesNotConfirmEOU() throws {
        var script = Self.script
        script[4] = nil
        let out = try run(ScriptedEOUModels(script: script), total: streamSamples(lastRegularChunk: 3))
        #expect(out.encoderCalls == 5, "4 regular chunks + 1 trailing chunk")
        #expect(out.nativeFinals == ["okay"])
        #expect(out.recordingFinal == "okay" && out.openAtFlush == nil)
    }

    @Test func eouConfirmedInTrailingChunkLosesTheSegment() throws {
        let out = try run(ScriptedEOUModels(script: Self.script), total: streamSamples(lastRegularChunk: 3))
        #expect(out.encoderCalls == 5)
        // Characterization of StreamingSession.swift:217-228: the trailing processChunk returns
        // the "okay" final, finalize() discards it (`_ =`), and the pending-token list is then
        // empty, so finish() returns nothing.
        #expect(out.nativeFinals.isEmpty)
        #expect(out.recordingPartials.last == "okay")
        #expect(out.recordingFinal == "", "the recording final drops the open segment silently")
        #expect(out.openAtFlush == "okay")
        withKnownIssue("F04b: a final produced by finalize()'s trailing chunk is discarded") {
            #expect(out.nativeFinals == ["okay"])
            #expect(out.recordingFinal == "okay")
        }
    }
}

// MARK: - Additional native observations (not in the review's two checks)

struct NativeCoverageObservationTests {
    /// Each chunk decodes `outputFrames` new frames (5120 samples); finalize() runs only one
    /// trailing chunk, so audio beyond `5120 * encoderCalls` is never decoded (F04c).
    @Test func audioAfterTheTrailingChunkIsNeverDecoded() throws {
        let total = streamSamples(lastRegularChunk: 2)               // 23040 samples
        let out = try run(ScriptedEOUModels(script: [:]), total: total)
        #expect(out.encoderCalls == 4)
        #expect(total - out.encoderCalls * shiftSamples == 2560, "last 160 ms never reaches the decoder")
    }

    /// Exact undecoded tail for the two Phase 1 AMI crops, from the real session loop.
    @Test(arguments: [(16_638_080, 3249, 3200), (19_200_000, 3750, 0)])
    func undecodedTailForPhase1Crops(total: Int, calls: Int, undecoded: Int) throws {
        let out = try run(ScriptedEOUModels(script: [:]), total: total)
        #expect(out.encoderCalls == calls)
        #expect(max(0, total - out.encoderCalls * shiftSamples) == undecoded)
    }

    /// RNNTGreedyDecoder stops the whole chunk at an `<EOU>` token, so the chunk's later
    /// frames never reach the joint (F04d). A token aligned to such a frame is never emitted.
    @Test func framesAfterAnEOUTokenInTheSameChunkAreSkipped() throws {
        let models = ScriptedEOUModels(script: [1: [0: [Tok.eou], 2: [Tok.so]], 2: [0: [Tok.okay]]])
        let out = try run(models, total: streamSamples(lastRegularChunk: 3))
        #expect(!models.jointFrames.contains { $0 == (1, 1) || $0 == (1, 2) || $0 == (1, 3) })
        #expect(models.jointFrames.contains { $0 == (2, 3) }, "a chunk without EOU decodes all four frames")
        #expect(out.recordingFinal == "okay", "the token scripted at (chunk 1, frame 2) is never emitted")
    }
}
