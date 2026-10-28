import AudioCore
import BenchmarkSupport
import Foundation
import Testing

/// V03: exact index/rate mappings including the final partial frame and overflow rejection.
struct SampleClockTests {
    @Test(arguments: [
        (16_000, 10, 160), (16_000, 20, 320), (16_000, 40, 640), (16_000, 80, 1280),
        (48_000, 10, 480), (44_100, 10, 441), (44_100, 20, 882), (8_000, 10, 80), (22_050, 20, 441),
    ] as [(Int64, Int64, Int64)])
    func frameSizes(_ rate: Int64, _ frameMS: Int64, _ expected: Int64) throws {
        #expect(try SampleClock.frameSamples(sampleRateHz: rate, frameMS: frameMS) == expected)
    }

    @Test(arguments: [(22_050, 10), (11_025, 10), (16_000, 25), (16_000, 0), (1, 20)] as [(Int64, Int64)])
    func nonIntegralOrUnsupportedFramesRejected(_ rate: Int64, _ frameMS: Int64) {
        #expect(throws: ValidationError.self) { _ = try SampleClock.frameSamples(sampleRateHz: rate, frameMS: frameMS) }
    }

    @Test func endOfFrameMediaDeadlines() throws {
        #expect(try SampleClock.mediaDeadlineNS(endSample: 320, sampleRateHz: 16_000) == 20_000_000)
        #expect(try SampleClock.mediaDeadlineNS(endSample: 16_100, sampleRateHz: 16_000) == 1_006_250_000)
        #expect(try SampleClock.mediaDeadlineNS(endSample: 0, sampleRateHz: 16_000) == 0)
        // 1/44100 s = 22675.736... ns -> floor
        #expect(try SampleClock.mediaDeadlineNS(endSample: 1, sampleRateHz: 44_100) == 22_675)
        // 12 minutes at 16 kHz, exact.
        #expect(try SampleClock.mediaDeadlineNS(endSample: 11_520_000, sampleRateHz: 16_000) == 720_000_000_000)
        // Large index well beyond any recording: 2^40 samples.
        #expect(try SampleClock.mediaDeadlineNS(endSample: 1 << 40, sampleRateHz: 16_000) == (1 << 40) * 62_500)
        #expect(throws: ArithmeticOverflow.self) {
            _ = try SampleClock.mediaDeadlineNS(endSample: Int64.max, sampleRateHz: 1)
        }
    }

    @Test func acceleratedOffsetsAreExactRationals() throws {
        let four = try ReplaySpeed(numerator: 4, denominator: 1)
        #expect(try SampleClock.acceleratedOffsetNS(endSample: 320, sampleRateHz: 16_000, speed: four) == 5_000_000)
        let threeHalves = try ReplaySpeed(numerator: 3, denominator: 2)
        // 320 * 1e9 * 2 / (16000 * 3) = 13_333_333.33 -> floor
        #expect(try SampleClock.acceleratedOffsetNS(endSample: 320, sampleRateHz: 16_000, speed: threeHalves) == 13_333_333)
        let unity = try ReplaySpeed(numerator: 1, denominator: 1)
        #expect(try SampleClock.acceleratedOffsetNS(endSample: 16_100, sampleRateHz: 16_000, speed: unity)
                == (try SampleClock.mediaDeadlineNS(endSample: 16_100, sampleRateHz: 16_000)))
        let odd = try ReplaySpeed.parseDecimal("2.000001")
        #expect(try SampleClock.acceleratedOffsetNS(endSample: 11_520_000, sampleRateHz: 16_000, speed: odd)
                == 359_999_820_000) // 720e9 * 1e6 / 2000001, floored
    }

    @Test func convertedCountsAndBoundaryMapping() throws {
        #expect(try SampleClock.convertedFrameCount(44_101, from: 44_100, to: 16_000) == 16_000)
        #expect(try SampleClock.convertedFrameCount(7, from: 16_000, to: 16_000) == 7)
        // Annotation boundaries: shared boundaries map identically; clamped to converted duration.
        let a = try SampleClock.mapBoundary(24_000, from: 48_000, to: 16_000, limit: 16_000)
        let b = try SampleClock.mapBoundary(24_000, from: 48_000, to: 16_000, limit: 16_000)
        #expect(a == 8_000 && a == b)
        #expect(try SampleClock.mapBoundary(48_000, from: 48_000, to: 16_000, limit: 15_999) == 15_999)
        #expect(try SampleClock.mapBoundary(1, from: 48_000, to: 16_000, limit: 16_000) == 0)
        #expect(try SampleClock.mapBoundary(2, from: 48_000, to: 16_000, limit: 16_000) == 1)
    }

    @Test func clockEvidence() throws {
        var rows: [JSONValue] = []
        for (end, rate) in [(320, 16_000), (16_100, 16_000), (1, 44_100), (11_520_000, 16_000), (1 << 40, 16_000)] as [(Int64, Int64)] {
            rows.append(.object(JSONObject([("end_sample", .int(end)), ("sample_rate_hz", .int(rate)),
                                            ("media_deadline_ns", .int(try SampleClock.mediaDeadlineNS(endSample: end, sampleRateHz: rate)))])))
        }
        Evidence.write("V03/clock.json", .array(rows))
    }
}
