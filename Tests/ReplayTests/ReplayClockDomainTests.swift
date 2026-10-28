import AudioCore
import BenchmarkSupport
import Foundation
import Replay
import Testing

/// V10 foundations: real and virtual clock domains never mix.
struct ReplayClockDomainTests {
    @Test func stepContextsCarryVirtualTimeOnly() async throws {
        let seen = Seen()
        _ = try await ReplayScheduler.run(spool: try preparedSpool("mono16k_pcm16_short_319"),
                                          configuration: try configuration(.step), clock: FakeRunClock()) {
            await seen.add($0, $1)
        }
        for context in await seen.contexts {
            #expect(context.plannedDeadlineNS == nil, "no live deadline exists in step mode")
            #expect(context.mediaDeadlineVirtualNS != nil && context.deliveredVirtualNS != nil)
        }
    }

    @Test func realtimeContextsCarryRealTimeOnly() async throws {
        let seen = Seen()
        _ = try await ReplayScheduler.run(spool: try preparedSpool("mono16k_pcm16_short_319"),
                                          configuration: try configuration(.realtime), clock: FakeRunClock()) {
            await seen.add($0, $1)
        }
        for context in await seen.contexts {
            #expect(context.plannedDeadlineNS != nil)
            #expect(context.mediaDeadlineVirtualNS == nil && context.deliveredVirtualNS == nil)
            #expect(context.offerNS <= context.entryNS && context.entryNS <= context.dequeueNS)
        }
    }

    /// A consumer advancing virtual time (the M3 mock-delay mechanism) moves only
    /// the virtual clock; the real run clock is untouched and nothing sleeps.
    @Test func virtualDelayNeverTouchesRealClock() async throws {
        let clock = FakeRunClock(startNS: 500)
        let virtual = VirtualClock()
        let trace = try await ReplayScheduler.run(spool: try preparedSpool("mono16k_pcm16_tone440_1s"),
                                                  configuration: try configuration(.step), clock: clock,
                                                  virtualClock: virtual) { _, _ in
            await virtual.advance(byNS: 30_000_000) // 30 ms delay per 20 ms chunk
        }
        try trace.verifyCoverage(lossless: true)
        #expect(clock.nowNS() == 500, "real clock did not move")
        #expect(clock.recordedSleeps.isEmpty)
        // With 30 ms of virtual work per 20 ms frame, delivery falls behind the media deadline deterministically.
        let delivered = trace.records.compactMap(\.deliveredVirtualNS)
        #expect(delivered.first == 20_000_000)
        #expect(delivered[1] == 50_000_000, "max(deadline 40 ms, 20 ms + 30 ms delay)")
        // Chunk k is delivered at 20 ms + 30 ms * k; the last (k = 49) at 1.49 s, plus its own 30 ms.
        #expect(delivered.last == 1_490_000_000)
        #expect(await virtual.nowNS == 1_520_000_000)
    }

    @Test func virtualClockNeverMovesBackwards() async {
        let virtual = VirtualClock()
        #expect(await virtual.advance(to: 100) == 100)
        #expect(await virtual.advance(to: 40) == 100)
        #expect(await virtual.advance(byNS: 5) == 105)
    }
}
