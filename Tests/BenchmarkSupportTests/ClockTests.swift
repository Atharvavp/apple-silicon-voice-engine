import BenchmarkSupport
import Foundation
import Testing

struct ClockTests {
    @Test func durationConversionIsIntegerAndChecked() throws {
        #expect(try DurationNS.nanoseconds(.seconds(1)) == 1_000_000_000)
        #expect(try DurationNS.nanoseconds(.nanoseconds(5)) == 5)
        #expect(try DurationNS.nanoseconds(.milliseconds(20)) == 20_000_000)
        // 1.999999999 ns of attoseconds truncates toward zero.
        #expect(try DurationNS.nanoseconds(Duration(secondsComponent: 3, attosecondsComponent: 1_999_999_999)) == 3_000_000_001)
        #expect(throws: ArithmeticOverflow.self) { _ = try DurationNS.nanoseconds(.seconds(Int64.max)) }
    }

    @Test func checkedMulDivUses128BitIntermediates() throws {
        // End-of-frame media deadline for a very large sample index at 16 kHz:
        // 2^40 * 1e9 / 16000 = 2^40 * 62500, exact.
        #expect(try CheckedMath.mulDivFloor(1 << 40, 1_000_000_000, 16_000) == (1 << 40) * 62_500)
        // a * b overflows int64 but the quotient fits.
        #expect(try CheckedMath.mulDivFloor(Int64.max, 1_000, 1_000) == Int64.max)
        #expect(try CheckedMath.mulDivFloor(7, 3, 2) == 10)
        #expect(throws: ArithmeticOverflow.self) { _ = try CheckedMath.mulDivFloor(Int64.max, 2, 1) }
        #expect(throws: ArithmeticOverflow.self) { _ = try CheckedMath.mulDivFloor(-1, 2, 1) }
        #expect(throws: ArithmeticOverflow.self) { _ = try CheckedMath.mulDivFloor(1, 2, 0) }
    }

    /// Plan D2 item 5: Nout = floor((Nin * Rout + floor(Rin/2)) / Rin). Expected values computed by hand.
    @Test(arguments: [
        (441_000, 44_100, 16_000, 160_000), (1, 48_000, 16_000, 0), (2, 48_000, 16_000, 1),
        (3, 48_000, 16_000, 1), (1, 44_100, 16_000, 0), (3, 44_100, 16_000, 1), (0, 48_000, 16_000, 0),
        (16_000, 16_000, 16_000, 16_000), (1, 8_000, 16_000, 2),
    ] as [(Int64, Int64, Int64, Int64)])
    func halfUpOutputCount(_ input: Int64, _ sourceRate: Int64, _ targetRate: Int64, _ expected: Int64) throws {
        #expect(try CheckedMath.mulDivHalfUp(input, targetRate, sourceRate) == expected)
    }

    @Test func fakeClockJumpsToDeadlines() async throws {
        let clock = FakeRunClock(startNS: 100)
        #expect(clock.nowNS() == 100)
        try await clock.sleep(untilNS: 20_000_000)
        #expect(clock.nowNS() == 20_000_000)
        try await clock.sleep(untilNS: 5) // past deadline: time never moves backwards
        #expect(clock.nowNS() == 20_000_000)
        clock.advance(byNS: 7)
        #expect(clock.nowNS() == 20_000_007)
        #expect(clock.recordedSleeps == [20_000_000, 5])
    }

    @Test func continuousClockIsMonotonicAndSleepsToAbsoluteDeadlines() async throws {
        let clock = ContinuousRunClock()
        var previous = clock.nowNS()
        for _ in 0..<10_000 {
            let now = clock.nowNS()
            #expect(now >= previous)
            previous = now
        }
        #expect(clock.minimumResolutionNS > 0)
        let deadline = clock.nowNS() + 5_000_000
        try await clock.sleep(untilNS: deadline)
        #expect(clock.nowNS() >= deadline)
        let before = clock.nowNS()
        try await clock.sleep(untilNS: 0) // already passed: returns without sleeping
        #expect(clock.nowNS() - before < 5_000_000)
    }

    @Test func cancelledSleepThrows() async {
        let clock = ContinuousRunClock()
        let task = Task { try await clock.sleep(untilNS: clock.nowNS() + 10_000_000_000) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
