import AudioCore
import BenchmarkSupport
import Foundation
import Testing

func prepare(_ name: String, target: Int64 = 16_000) throws -> PreparedAudio {
    try AudioPreparer.prepare(source: fixtureURL(name), sourceID: name, targetRateHz: target,
                              scratchDirectory: try makeScratch())
}

func spoolSamples(_ spool: PCMSpool) throws -> [Float] {
    try PCMSpoolReader(spool).read(0, spool.frameCount)
}

private func rms(_ values: ArraySlice<Float>) -> Double {
    (values.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(values.count)).squareRoot()
}

private func centralWindow(_ values: [Float]) -> ArraySlice<Float> {
    let margin = values.count / 10
    return values[margin..<(values.count - margin)]
}

/// V02: exact converted counts, documented endpoint handling, quality and alignment probes.
struct ConversionTests {
    static var validNames: [String] { FixtureCatalog.shared.valid.map(\.name) }

    @Test(arguments: validNames)
    func convertedCountMatchesIndependentGolden(_ name: String) throws {
        let golden = try #require(FixtureCatalog.shared.convertedFrames[name])
        let prepared = try prepare(name)
        #expect(prepared.spool.frameCount == golden)
        #expect(prepared.conversion.intendedFrames == golden)
        #expect(abs(prepared.conversion.nativeFrames - golden) <= 1)
        #expect(prepared.conversion.trimmedTailFrames + prepared.conversion.zeroExtendedTailFrames
                == abs(prepared.conversion.nativeFrames - golden))
        #expect(prepared.source.frameCount == FixtureCatalog.shared.valid.first { $0.name == name }!.frames)
        #expect(prepared.source.sampleRateHz != 16_000 || prepared.conversion.bypassed)
        let reread = try SHA256Hex.file(prepared.spool.url)
        #expect(reread.sha256 == prepared.spool.sha256 && reread.byteCount == golden * 4)
    }

    @Test func sameRateBypassIsSampleExact() throws {
        let (_, decoded) = try decodeMono("mono16k_f32_impulse")
        let prepared = try prepare("mono16k_f32_impulse")
        #expect(prepared.conversion.bypassed)
        #expect(try spoolSamples(prepared.spool) == decoded)
    }

    @Test func conversionIsDeterministicAndBlockSplitInvariant() throws {
        let first = try prepare("mono48k_f32_tone1k")
        let second = try prepare("mono48k_f32_tone1k")
        #expect(first.spool.sha256 == second.spool.sha256)
        // Re-run the converter on the same mono source with different input callback sizes.
        var hashes: [Int64: String] = [:]
        for block: Int64 in [4096, 1000, 97] {
            let scratch = try makeScratch()
            let source = try PCMSpoolWriter(url: scratch.appendingPathComponent("src.f32le"))
            try WAVDecoder.decode(fixtureURL("mono48k_f32_tone1k"),
                                  info: try WAVInspector.inspect(fixtureURL("mono48k_f32_tone1k"))) { try source.append($0) }
            let writer = try PCMSpoolWriter(url: scratch.appendingPathComponent("out.f32le"))
            let result = try SampleRateConverter.convert(try source.finish(sampleRateHz: 48_000), to: 16_000,
                                                         writer: writer, inputBlockFrames: block)
            if result.nativeFrames == 16_001 { try writer.truncateTail(frames: 1) }
            hashes[block] = try writer.finish(sampleRateHz: 16_000).sha256
        }
        Evidence.write("V02/split-block.json", .object(JSONObject(hashes.sorted { $0.key < $1.key }.map {
            ("input_block_\($0.key)", .string($0.value)) })))
        #expect(Set(hashes.values).count == 1, "output depends on input block split: \(hashes)")
    }

    @Test func qualityAndAlignmentProbes() throws {
        var probes: [(String, JSONValue)] = []

        let tone = try spoolSamples(try prepare("mono48k_f32_tone1k").spool)
        let toneRatio = rms(centralWindow(tone)) / (0.5 / 2.0.squareRoot())
        probes.append(("tone1k_48k_rms_ratio", .double(toneRatio)))
        #expect(abs(toneRatio - 1) <= 0.01, "in-band RMS ratio \(toneRatio)")

        let tone441 = try spoolSamples(try prepare("mono44k1_pcm16_tone1k").spool)
        let ratio441 = rms(centralWindow(tone441)) / (0.5 / 2.0.squareRoot())
        probes.append(("tone1k_44k1_rms_ratio", .double(ratio441)))
        #expect(abs(ratio441 - 1) <= 0.01, "in-band RMS ratio \(ratio441)")

        let stereo = try spoolSamples(try prepare("stereo48k_pcm24_tone1k").spool)
        let stereoRatio = rms(centralWindow(stereo)) / (0.5 / 2.0.squareRoot())
        probes.append(("tone1k_48k_stereo_pcm24_rms_ratio", .double(stereoRatio)))
        #expect(abs(stereoRatio - 1) <= 0.01)

        let dc = centralWindow(try spoolSamples(try prepare("mono48k_f32_dc").spool))
        let dcError = abs(dc.reduce(0.0) { $0 + Double($1) } / Double(dc.count) - 0.25)
        probes.append(("dc_48k_mean_abs_error", .double(dcError)))
        #expect(dcError <= 1e-4, "DC error \(dcError)")

        let high = try spoolSamples(try prepare("mono48k_f32_tone12k").spool)
        let attenuation = 20 * log10((0.5 / 2.0.squareRoot()) / max(rms(centralWindow(high)), 1e-12))
        probes.append(("tone12k_attenuation_db", .double(attenuation)))
        #expect(attenuation >= 30, "12 kHz attenuation \(attenuation) dB")

        let impulsePrepared = try prepare("mono48k_f32_impulse")
        let impulse = try spoolSamples(impulsePrepared.spool)
        let peak = impulse.indices.max { abs(impulse[$0]) < abs(impulse[$1]) }!
        probes.append(("impulse_expected_index", .int(8_000)))
        probes.append(("impulse_peak_index", .int(Int64(peak))))
        probes.append(("impulse_peak_value", .double(Double(impulse[peak]))))
        probes.append(("impulse_native_frames", .int(impulsePrepared.conversion.nativeFrames)))
        probes.append(("prime_leading_frames", .int(impulsePrepared.conversion.primeLeadingFrames)))
        probes.append(("prime_trailing_frames", .int(impulsePrepared.conversion.primeTrailingFrames)))
        Evidence.write("V02/src-probes.json", .object(JSONObject(probes)))
        #expect(peak == 8_000, "impulse at 48 kHz index 24000 must land at 16 kHz index 8000 (got \(peak))")
    }

    @Test func conversionEvidence() throws {
        var rows: [JSONValue] = []
        for entry in FixtureCatalog.shared.valid {
            let prepared = try prepare(entry.name)
            var object = JSONObject([("fixture", .string(entry.name))])
            guard case .object(let record) = prepared.conversion.toJSON() else { continue }
            for member in record.members { object.set(member.key, member.value) }
            object.set("source_sha256", .string(prepared.source.sha256))
            rows.append(.object(object))
        }
        Evidence.write("V02/conversions.json", .array(rows))
    }

    @Test func spoolNeverOverwritesExistingFile() throws {
        let scratch = try makeScratch()
        _ = try prepare("mono16k_pcm16_tone440_1s")
        _ = try AudioPreparer.prepare(source: fixtureURL("mono16k_pcm16_tone440_1s"), sourceID: "x",
                                      targetRateHz: 16_000, scratchDirectory: scratch)
        #expect(throws: AudioError.self) {
            _ = try AudioPreparer.prepare(source: fixtureURL("mono16k_pcm16_tone440_1s"), sourceID: "x",
                                          targetRateHz: 16_000, scratchDirectory: scratch)
        }
    }
}
