import AudioCore
import BenchmarkSupport
import Foundation
import Testing

func decodeMono(_ name: String) throws -> (WAVInfo, [Float]) {
    let url = fixtureURL(name)
    let info = try WAVInspector.inspect(url)
    var samples: [Float] = []
    try WAVDecoder.decode(url, info: info) { samples.append(contentsOf: $0) }
    return (info, samples)
}

/// V01: supported-format matrix, exact frame counts, typed errors for malformed input.
struct WAVDecoderTests {
    static var validNames: [String] { FixtureCatalog.shared.valid.map(\.name) }
    static var malformedNames: [String] { FixtureCatalog.shared.malformed.map(\.name) }

    @Test(arguments: validNames)
    func supportedFixtureDecodesWithExactCounts(_ name: String) throws {
        let expected = try #require(FixtureCatalog.shared.valid.first { $0.name == name })
        let (info, samples) = try decodeMono(name)
        #expect(info.sampleRateHz == expected.sampleRateHz)
        #expect(info.channels == expected.channels)
        #expect(info.encoding.bitsPerSample == expected.bits)
        #expect(info.encoding.rawValue == expected.encoding.replacingOccurrences(of: "extensible_", with: ""))
        #expect(info.extensible == expected.encoding.hasPrefix("extensible_"))
        #expect(info.frameCount == expected.frames)
        #expect(Int64(samples.count) == expected.frames, "decoded mono frame count")
        let allFinite = samples.allSatisfy { $0.isFinite }
        #expect(allFinite)
    }

    @Test(arguments: malformedNames)
    func malformedFixtureFailsWithTypedError(_ name: String) throws {
        let expected = try #require(FixtureCatalog.shared.malformed.first { $0.name == name }).expectedError
        let url = repoURL("datasets/fixtures/audio/malformed/\(name).wav")
        do {
            let info = try WAVInspector.inspect(url)
            try WAVDecoder.decode(url, info: info) { _ in }
            Issue.record("\(name) was accepted")
        } catch let error as AudioError {
            #expect(error.caseName == expected, "\(name): \(error)")
        }
    }

    @Test(arguments: [("mono16k_pcm16_fullscale", 16), ("mono16k_pcm24_fullscale", 24), ("mono16k_pcm32_fullscale", 32)])
    func integerScalingWithinOneLSB(_ name: String, _ bits: Int) throws {
        let codes: [Int64] = [0, (1 << (bits - 1)) - 1, -(1 << (bits - 1)), 1, -1, 1 << (bits - 2), -(1 << (bits - 2))]
        let (_, samples) = try decodeMono(name)
        try #require(samples.count == codes.count)
        let scale = Double(1 << (bits - 1))
        var rows: [JSONValue] = []
        for (code, decoded) in zip(codes, samples) {
            let expected = Double(code) / scale
            let tolerance = max(1 / scale, Double(Float(expected).ulp))
            #expect(abs(Double(decoded) - expected) <= tolerance, "\(name) code \(code): \(decoded) vs \(expected)")
            rows.append(.object(JSONObject([("code", .int(code)), ("decoded", .double(Double(decoded))),
                                            ("expected", .double(expected))])))
        }
        Evidence.write("V01/scaling-\(bits)bit.json", .array(rows))
    }

    @Test func floatSamplesOutsideUnitRangeAreNotClipped() throws {
        let (_, samples) = try decodeMono("mono16k_f32_outside_unit")
        #expect(samples == [0.0, 1.5, -2.0, 0.125])
    }

    @Test func stereoDownmixIsArithmeticMean() throws {
        let (_, cancel) = try decodeMono("stereo16k_pcm16_cancel")
        #expect(cancel.allSatisfy { abs($0) <= 1e-6 }, "L = -R must cancel")
        let (_, dc) = try decodeMono("stereo16k_f32_dc")
        #expect(dc.count == 4_000)
        #expect(dc.allSatisfy { abs($0 - 0.5) <= 1e-6 }, "mean of 0.25 and 0.75")
    }

    @Test func emptyWAVIsZeroFrames() throws {
        let (info, samples) = try decodeMono("mono16k_pcm16_empty")
        #expect(info.frameCount == 0)
        #expect(samples.isEmpty)
    }

    @Test func formatMatrixEvidence() throws {
        var rows: [JSONValue] = []
        for entry in FixtureCatalog.shared.valid {
            let info = try WAVInspector.inspect(fixtureURL(entry.name))
            rows.append(.object(JSONObject([
                ("fixture", .string(entry.name)), ("encoding", .string(info.encoding.rawValue)),
                ("extensible", .bool(info.extensible)), ("channels", .int(Int64(info.channels))),
                ("sample_rate_hz", .int(info.sampleRateHz)), ("frames", .int(info.frameCount)), ("status", .string("supported")),
            ])))
        }
        for entry in FixtureCatalog.shared.malformed {
            let url = repoURL("datasets/fixtures/audio/malformed/\(entry.name).wav")
            var observed = "accepted"
            do {
                try WAVDecoder.decode(url, info: try WAVInspector.inspect(url)) { _ in }
            } catch let error as AudioError {
                observed = error.caseName
            }
            rows.append(.object(JSONObject([("fixture", .string(entry.name)), ("expected_error", .string(entry.expectedError)),
                                            ("observed_error", .string(observed))])))
        }
        Evidence.write("V01/formats.json", .array(rows))
    }
}
