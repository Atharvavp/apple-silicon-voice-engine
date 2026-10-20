@testable import AudioCore
import BenchmarkSupport
import Foundation
import Testing

/// Writes `samples` as a finished mono spool at `rate` in a fresh scratch directory.
func makeSpool(_ samples: [Float], rate: Int64) throws -> (PCMSpool, URL) {
    let scratch = try makeScratch()
    let writer = try PCMSpoolWriter(url: scratch.appendingPathComponent("source.f32le"))
    try writer.append(samples)
    return (try writer.finish(sampleRateHz: rate), scratch)
}

func resampled(_ samples: [Float], from rate: Int64, to target: Int64, policy: EndpointPolicy = .allowOneFrame,
               block: Int64 = 4096) throws -> (PCMSpool, ConversionRecord, [Float]) {
    let (source, scratch) = try makeSpool(samples, rate: rate)
    let (spool, record) = try AudioPreparer.resample(source, to: target,
                                                     output: scratch.appendingPathComponent("out.f32le"),
                                                     endpointPolicy: policy, inputBlockFrames: block)
    return (spool, record, try PCMSpoolReader(spool).read(0, spool.frameCount))
}

/// Deterministic non-periodic test signal (same shape as the fixture generator's ramp).
func ramp(_ count: Int64) -> [Float] {
    (0..<count).map { Float(Double(($0 * 37) % 2001 - 1000) / 1000.0 * 0.5) }
}

/// H3: resampling edge cases. Endpoint corrections must always be visible.
struct ResamplingEdgeTests {
    static let ratePairs: [(Int64, Int64)] = [
        (48_000, 16_000), (44_100, 16_000), (22_050, 16_000), (32_000, 16_000), (11_025, 16_000),
        (8_000, 16_000), (96_000, 16_000), (16_000, 48_000), (16_000, 44_100),
    ]
    static let lengths: [Int64] = Array(0...12) + [50, 100, 101, 999, 1000, 1001, 4095, 4096, 4097, 22_049, 22_050,
                                                   44_099, 44_100, 44_101]

    /// Converts every (rate pair, length) and records native vs. policy counts.
    @Test func endpointMatrixIsDisclosedAndBoundedByOneFrame() throws {
        var rows: [JSONValue] = []
        var corrections = 0
        for (source, target) in Self.ratePairs {
            for length in Self.lengths {
                let (spool, record, _) = try resampled(ramp(length), from: source, to: target)
                try record.validate()
                #expect(spool.frameCount == record.intendedFrames, "\(source)->\(target) n=\(length)")
                #expect(abs(record.nativeFrames - record.intendedFrames) <= 1)
                let corrected = record.nativeFrames != record.intendedFrames
                #expect(record.endpointStatus.isCorrection == corrected, "a correction is never reported as exact")
                if corrected {
                    corrections += 1
                    #expect(throws: AudioError.self, "strict benchmark validation must reject an undisclosed correction") {
                        try record.requireExactEndpoints()
                    }
                } else {
                    try record.requireExactEndpoints()
                }
                rows.append(.object(JSONObject([
                    ("source_rate_hz", .int(source)), ("target_rate_hz", .int(target)), ("source_frames", .int(length)),
                    ("intended_frames", .int(record.intendedFrames)), ("native_frames", .int(record.nativeFrames)),
                    ("endpoint_status", .string(record.endpointStatus.rawValue)),
                ])))
            }
        }
        Evidence.write("M2-hardening/H3/endpoint-matrix.json", .object(JSONObject([
            ("rule", .string("intended = floor((Nin*Rout + floor(Rin/2)) / Rin)")),
            ("cases", .int(Int64(rows.count))), ("corrections", .int(Int64(corrections))), ("rows", .array(rows)),
        ])))
    }

    /// Data-driven: wherever the documented policy needed a correction, `strict` must refuse;
    /// wherever it did not, `strict` must produce the identical spool.
    @Test func strictPolicyRefusesExactlyTheCorrectedCases() throws {
        var refused = 0
        for (source, target) in Self.ratePairs {
            for length in Self.lengths where length <= 101 {
                let samples = ramp(length)
                let (lenient, lenientRecord, _) = try resampled(samples, from: source, to: target)
                if lenientRecord.endpointStatus.isCorrection {
                    refused += 1
                    #expect(throws: AudioError.self) {
                        _ = try resampled(samples, from: source, to: target, policy: .strict)
                    }
                } else {
                    let (strict, strictRecord, _) = try resampled(samples, from: source, to: target, policy: .strict)
                    #expect(strict.sha256 == lenient.sha256)
                    #expect(strictRecord.endpointPolicy == .strict && !strictRecord.endpointStatus.isCorrection)
                }
            }
        }
        // Guard against a vacuous test: the matrix must include at least one corrected case.
        #expect(refused > 0, "no correction occurred, so the strict path was not exercised")
    }

    @Test func inconsistentRecordsFailValidation() throws {
        func record(native: Int64 = 3, intended: Int64 = 3, trimmed: Int64 = 0, extended: Int64 = 0, bypassed: Bool = false,
                    source: Int64 = 7, policy: EndpointPolicy = .allowOneFrame) -> ConversionRecord {
            ConversionRecord(policy: "p", downmixPolicy: "d", endpointPolicy: policy, sourceFrames: source,
                             sourceRateHz: 44_100, targetRateHz: 16_000, intendedFrames: intended, nativeFrames: native,
                             trimmedTailFrames: trimmed, zeroExtendedTailFrames: extended, bypassed: bypassed,
                             algorithm: "normal", quality: "max", primeMethod: "normal", primeLeadingFrames: 0,
                             primeTrailingFrames: 0, convertedSHA256: String(repeating: "0", count: 64))
        }
        try record().validate()
        try record(native: 2, extended: 1).validate()
        try record(native: 4, trimmed: 1).validate()
        let bad = [
            record(native: 4),                                   // off by one, not corrected
            record(native: 2, trimmed: 1, extended: 1),          // both corrections at once
            record(native: 5, trimmed: 2),                       // more than one frame trimmed
            record(native: 2, extended: 1, policy: .strict),     // strict policy cannot record a correction
            record(native: 4, intended: 4),                      // intended disagrees with the half-up rule (7 @44.1k -> 3)
            record(native: 2, extended: 1, bypassed: true),      // bypass must be identity
        ]
        for bad in bad {
            #expect(throws: AudioError.self) { try bad.validate() }
        }
    }

    /// Impulses placed where the exact output position is an integer must peak there,
    /// for integer and non-integer ratios, down- and upsampling.
    @Test(arguments: [
        (44_100, 16_000, 44_100, 22_050, 8_000), (22_050, 16_000, 22_050, 11_025, 8_000),
        (11_025, 16_000, 22_050, 11_025, 16_000), (96_000, 16_000, 96_000, 48_000, 8_000),
        (32_000, 16_000, 32_000, 16_000, 8_000), (8_000, 16_000, 8_000, 4_000, 8_000),
        (16_000, 48_000, 16_000, 8_000, 24_000), (16_000, 44_100, 16_000, 160, 441),
    ] as [(Int64, Int64, Int64, Int64, Int64)])
    func interiorImpulseLandsAtExactPosition(_ source: Int64, _ target: Int64, _ length: Int64, _ at: Int64,
                                             _ expected: Int64) throws {
        var samples = [Float](repeating: 0, count: Int(length))
        samples[Int(at)] = 1
        let (_, _, output) = try resampled(samples, from: source, to: target)
        let peak = output.indices.max { abs(output[$0]) < abs(output[$1]) }!
        #expect(Int64(peak) == expected, "\(source)->\(target): impulse at \(at) peaked at \(peak), expected \(expected)")
    }

    /// Impulses at the first and last input samples: the peak is the floor or ceiling of the
    /// exact output position (clamped to the output), and the impulse is not lost.
    @Test(arguments: [(48_000, 16_000), (44_100, 16_000), (22_050, 16_000), (16_000, 44_100)] as [(Int64, Int64)])
    func boundaryImpulsesSurvive(_ source: Int64, _ target: Int64) throws {
        let length = source / 10
        var rows: [(String, JSONValue)] = []
        for at in [Int64(0), 1, 2, length - 2, length - 1] {
            var samples = [Float](repeating: 0, count: Int(length))
            samples[Int(at)] = 1
            let (_, record, output) = try resampled(samples, from: source, to: target)
            let peak = Int64(output.indices.max { abs(output[$0]) < abs(output[$1]) }!)
            let exact = Double(at) * Double(target) / Double(source)
            let last = Int64(output.count - 1)
            let allowed = Set([Int64(exact.rounded(.down)), Int64(exact.rounded(.up))].map { min($0, last) })
            #expect(allowed.contains(peak), "\(source)->\(target) impulse at \(at): peak \(peak), exact \(exact)")
            let peakValue = abs(output[Int(peak)])
            #expect(peakValue > 0.05, "boundary impulse at \(at) was attenuated to \(peakValue)")
            rows.append(("impulse_at_\(at)", .object(JSONObject([
                ("exact_output_position", .double(exact)), ("peak_index", .int(peak)),
                ("peak_value", .double(Double(output[Int(peak)]))),
                ("output_sum", .double(output.reduce(0.0) { $0 + Double($1) })),
                ("endpoint_status", .string(record.endpointStatus.rawValue)),
            ]))))
        }
        Evidence.write("M2-hardening/H3/boundary-impulses-\(source)-\(target).json", .object(JSONObject(rows)))
    }

    /// Output must not depend on how input is split across converter callbacks.
    @Test(arguments: [(44_100, 16_000), (22_050, 16_000), (11_025, 16_000), (48_000, 16_000), (16_000, 44_100)]
          as [(Int64, Int64)])
    func inputBlockSizeInvariance(_ source: Int64, _ target: Int64) throws {
        var hashes: [Int64: String] = [:]
        var counts: [Int64: Int64] = [:]
        for block: Int64 in [1, 7, 97, 1000, 4096] {
            let (spool, record, _) = try resampled(ramp(2_003), from: source, to: target, block: block)
            hashes[block] = spool.sha256
            counts[block] = record.nativeFrames
        }
        #expect(Set(hashes.values).count == 1, "\(source)->\(target): output depends on input block split: \(hashes)")
        #expect(Set(counts.values).count == 1, "\(source)->\(target): native count depends on block split: \(counts)")
        Evidence.write("M2-hardening/H3/block-invariance-\(source)-\(target).json", .object(JSONObject(
            hashes.sorted { $0.key < $1.key }.map { ("block_\($0.key)", .string("\($0.value) native=\(counts[$0.key]!)")) })))
    }

    /// The WAV → prepare path for very short inputs, against the independent Python goldens.
    @Test(arguments: ["mono44k1_f32_len1", "mono44k1_f32_len7", "mono22k05_f32_len2", "mono96k_f32_len3",
                      "mono11k025_f32_len10", "mono48k_f32_len5"])
    func shortWAVFixturesPrepareToGoldenCounts(_ name: String) throws {
        let golden = try #require(FixtureCatalog.shared.convertedFrames[name])
        let prepared = try prepare(name)
        #expect(prepared.spool.frameCount == golden)
        try prepared.conversion.validate()
        #expect(prepared.conversion.endpointStatus.isCorrection == (prepared.conversion.nativeFrames != golden))
    }
}
