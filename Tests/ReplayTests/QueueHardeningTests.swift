import BenchmarkSupport
import Foundation
import os
import Replay
import Testing

/// H1: bounded-queue concurrency hardening. Every scenario repeats many rounds
/// under a wall-clock bound. Exactly-once resumption is enforced two ways: a
/// double resume of a `CheckedContinuation` traps the test process, and a lost
/// resume trips the timeout. Accounting checks that every successful send is
/// delivered exactly once and every cancelled or failed send is never delivered.
struct QueueHardeningTests {
    static let rounds = 200

    private func waitFor(_ queue: BoundedQueue<Int>, senders: Int = 0, receivers: Int = 0) async {
        while true {
            let blocked = await queue.waitingSenders
            let waiting = await queue.waitingReceivers
            if blocked >= senders && waiting >= receivers { return }
            await Task.yield()
        }
    }

    private func drain(_ queue: BoundedQueue<Int>) async throws -> [Int] {
        var values: [Int] = []
        while let delivery = try await queue.receive() { values.append(delivery.element) }
        return values
    }

    @Test func producerCancellationWhileBlocked() async throws {
        try await withTimeout(60, "producer cancellation stress") {
            var counts = (cancelledThenAdmitted: 0, cancelledThrew: 0, uncancelledAdmitted: 0)
            for round in 0..<QueueHardeningTests.rounds {
                let queue = BoundedQueue<Int>(capacity: 2, policy: .block, clock: FakeRunClock())
                _ = try await queue.send(-1)
                _ = try await queue.send(-2)
                var senders: [Task<BoundedQueue<Int>.Admission, Error>] = []
                for k in 0..<4 {
                    let value = round * 10 + k
                    senders.append(Task { try await queue.send(value) })
                    await self.waitFor(queue, senders: k + 1) // fixes the FIFO blocking order
                }
                let cancelled = Set((0..<4).filter { (round >> $0) & 1 == 1 })
                for k in cancelled { senders[k].cancel() }
                // A consumer frees slots while cancellations are in flight.
                let consumer = Task { try await self.drain(queue) }
                var admitted: [Int] = []
                for (k, sender) in senders.enumerated() {
                    switch await sender.result {
                    case .success(.accepted):
                        admitted.append(round * 10 + k)
                        if cancelled.contains(k) { counts.cancelledThenAdmitted += 1 } else { counts.uncancelledAdmitted += 1 }
                    case .success(.dropped): Issue.record("block policy never drops")
                    case .failure(let error):
                        counts.cancelledThrew += 1
                        #expect(error is CancellationError, "only cancellation may fail a blocked send: \(error)")
                        #expect(cancelled.contains(k), "uncancelled sender \(k) failed")
                    }
                }
                #expect(admitted.count >= 4 - cancelled.count, "every uncancelled sender is admitted")
                await queue.close()
                let delivered = try await consumer.value
                #expect(delivered == [-1, -2] + admitted, "round \(round): admitted offers delivered once, in FIFO order")
                #expect(await queue.invariantViolations == [])
            }
            Evidence.write("M2-hardening/H1/producer-cancellation.json", .object(JSONObject([
                ("rounds", .int(Int64(QueueHardeningTests.rounds))), ("blocked_senders_per_round", .int(4)),
                ("cancelled_then_admitted", .int(Int64(counts.cancelledThenAdmitted))),
                ("cancelled_threw", .int(Int64(counts.cancelledThrew))),
                ("uncancelled_admitted", .int(Int64(counts.uncancelledAdmitted))),
            ])))
        }
    }

    @Test func consumerCancellationWhileWaiting() async throws {
        try await withTimeout(60, "consumer cancellation stress") {
            var counts = (cancelledThenServed: 0, cancelledThrew: 0, uncancelledServed: 0)
            for round in 0..<QueueHardeningTests.rounds {
                let queue = BoundedQueue<Int>(capacity: 4, policy: .block, clock: FakeRunClock())
                var receivers: [Task<BoundedQueue<Int>.Delivery?, Error>] = []
                for k in 0..<4 {
                    receivers.append(Task { try await queue.receive() })
                    await self.waitFor(queue, receivers: k + 1)
                }
                let cancelled = Set((0..<4).filter { (round >> $0) & 1 == 1 })
                for k in cancelled { receivers[k].cancel() }
                if round % 3 == 0 { await Task.yield() }
                for value in 0..<4 { _ = try await queue.send(value) }
                var received: [Int] = []
                for (k, receiver) in receivers.enumerated() {
                    switch await receiver.result {
                    case .success(let delivery?):
                        received.append(delivery.element)
                        if cancelled.contains(k) { counts.cancelledThenServed += 1 } else { counts.uncancelledServed += 1 }
                    case .success(nil): Issue.record("receiver \(k) got end-of-stream from an open queue")
                    case .failure(let error):
                        counts.cancelledThrew += 1
                        #expect(error is CancellationError)
                        #expect(cancelled.contains(k), "uncancelled receiver \(k) failed")
                    }
                }
                await queue.close()
                let leftover = try await self.drain(queue)
                #expect((received + leftover).sorted() == [0, 1, 2, 3], "round \(round): no value lost or duplicated")
                #expect(received == received.sorted(), "waiting receivers are served in FIFO order")
                #expect(await queue.invariantViolations == [])
            }
            Evidence.write("M2-hardening/H1/consumer-cancellation.json", .object(JSONObject([
                ("rounds", .int(Int64(QueueHardeningTests.rounds))), ("waiting_receivers_per_round", .int(4)),
                ("cancelled_then_served", .int(Int64(counts.cancelledThenServed))),
                ("cancelled_threw", .int(Int64(counts.cancelledThrew))),
                ("uncancelled_served", .int(Int64(counts.uncancelledServed))),
            ])))
        }
    }

    /// Cancellation of a blocked sender races the dequeue that would admit it.
    @Test func cancellationRacingAdmission() async throws {
        try await withTimeout(60, "cancellation vs admission race") {
            var outcomes = (admitted: 0, cancelled: 0)
            for round in 0..<(QueueHardeningTests.rounds * 5) {
                let queue = BoundedQueue<Int>(capacity: 1, policy: .block, clock: FakeRunClock())
                _ = try await queue.send(-1)
                let sender = Task { try await queue.send(round) }
                if round % 2 == 0 { await self.waitFor(queue, senders: 1) }
                async let freed = queue.receive()
                if round % 3 == 0 { await Task.yield() }
                sender.cancel()
                #expect(try await freed?.element == -1)
                let result = await sender.result
                await queue.close()
                let rest = try await self.drain(queue)
                switch result {
                case .success:
                    outcomes.admitted += 1
                    #expect(rest == [round], "admitted offer must be delivered exactly once")
                case .failure(let error):
                    outcomes.cancelled += 1
                    #expect(error is CancellationError)
                    #expect(rest.isEmpty, "cancelled offer must never be delivered")
                }
                #expect(await queue.invariantViolations == [])
            }
            Evidence.write("M2-hardening/H1/admission-race.json", .object(JSONObject([
                ("rounds", .int(Int64(QueueHardeningTests.rounds * 5))), ("admitted", .int(Int64(outcomes.admitted))),
                ("cancelled", .int(Int64(outcomes.cancelled))),
            ])))
        }
    }

    @Test func closeWakesAllWaitingReceivers() async throws {
        try await withTimeout(30, "close with many receivers") {
            let queue = BoundedQueue<Int>(capacity: 2, policy: .block, clock: FakeRunClock())
            let receivers = (0..<8).map { _ in Task { try await queue.receive() } }
            await self.waitFor(queue, receivers: 8)
            await queue.close()
            for receiver in receivers {
                let delivery = try await receiver.value
                #expect(delivery == nil)
            }
            #expect(await queue.invariantViolations == [])
        }
    }

    @Test func closeFailsAllBlockedSendersWithoutDeliveringThem() async throws {
        try await withTimeout(30, "close with many blocked senders") {
            let queue = BoundedQueue<Int>(capacity: 1, policy: .block, clock: FakeRunClock())
            _ = try await queue.send(0)
            let senders = (1...6).map { value in Task { try await queue.send(value) } }
            await self.waitFor(queue, senders: 6)
            await queue.close()
            for sender in senders {
                await #expect(throws: QueueError.closed) { _ = try await sender.value }
            }
            #expect(try await self.drain(queue) == [0], "only the admitted element is delivered")
            #expect(await queue.invariantViolations == [])
        }
    }

    @Test func failWakesAllWaitersOfEitherKind() async throws {
        try await withTimeout(30, "fail with many waiters") {
            let full = BoundedQueue<Int>(capacity: 1, policy: .block, clock: FakeRunClock())
            _ = try await full.send(0)
            let senders = (1...6).map { value in Task { try await full.send(value) } }
            await self.waitFor(full, senders: 6)
            await full.fail("recorder failed")
            for sender in senders {
                await #expect(throws: QueueError.failed("recorder failed")) { _ = try await sender.value }
            }
            await #expect(throws: QueueError.failed("recorder failed")) { _ = try await full.receive() }
            await #expect(throws: QueueError.failed("recorder failed")) { _ = try await full.send(9) }
            #expect(await full.invariantViolations == [])

            let empty = BoundedQueue<Int>(capacity: 1, policy: .block, clock: FakeRunClock())
            let receivers = (0..<6).map { _ in Task { try await empty.receive() } }
            await self.waitFor(empty, receivers: 6)
            await empty.fail("adapter failed")
            for receiver in receivers {
                await #expect(throws: QueueError.failed("adapter failed")) { _ = try await receiver.value }
            }
            await empty.close() // no effect after failure
            #expect(await empty.invariantViolations == [])
        }
    }

    /// Producers and consumers run concurrently (true interleaving of blocking and hand-off).
    @Test(arguments: [OverflowPolicy.block, .dropNewest])
    func concurrentProducersAndConsumers(_ policy: OverflowPolicy) async throws {
        try await withTimeout(60, "concurrent MPMC \(policy.rawValue)") {
            let queue = BoundedQueue<Int>(capacity: 2, policy: policy, clock: FakeRunClock(stepPerRead: 1))
            async let consumed: [(Int, Int64)] = withThrowingTaskGroup(of: [(Int, Int64)].self) { group in
                for c in 0..<3 {
                    group.addTask {
                        var seen: [(Int, Int64)] = []
                        while let delivery = try await queue.receive() {
                            seen.append((delivery.element, delivery.dequeueNS))
                            if (delivery.element + c) % 7 == 0 { await Task.yield() }
                        }
                        return seen
                    }
                }
                var all: [(Int, Int64)] = []
                for try await part in group { all += part }
                return all
            }
            let accepted = await withTaskGroup(of: [Int].self) { group in
                for p in 0..<3 {
                    group.addTask {
                        var mine: [Int] = []
                        for i in 0..<400 {
                            let value = p * 100_000 + i
                            if case .accepted = try? await queue.send(value) { mine.append(value) }
                        }
                        return mine
                    }
                }
                var all: [Int] = []
                for await part in group { all += part }
                return all
            }
            await queue.close()
            let deliveries = try await consumed
            #expect(deliveries.map(\.0).sorted() == accepted.sorted())
            let ordered = deliveries.sorted { $0.1 < $1.1 }.map(\.0)
            for p in 0..<3 {
                let mine = ordered.filter { $0 / 100_000 == p }
                #expect(mine == mine.sorted())
            }
            #expect(Set(deliveries.map(\.1)).count == deliveries.count, "dequeue stamps are unique")
            if policy == .block { #expect(accepted.count == 1_200) }
            #expect(await queue.droppedCount == 1_200 - accepted.count)
            #expect(await queue.maxDepth <= 2)
            #expect(await queue.invariantViolations == [])
        }
    }

    /// FIFO and sample accounting with sample-range elements (the replay use case).
    @Test(arguments: [OverflowPolicy.block, .dropNewest])
    func sampleRangeAccounting(_ policy: OverflowPolicy) async throws {
        try await withTimeout(30, "sample accounting \(policy.rawValue)") {
            struct Span: Sendable { let start: Int64, end: Int64 }
            let queue = BoundedQueue<Span>(capacity: 2, policy: policy, clock: FakeRunClock())
            let total: Int64 = 16_100, frame: Int64 = 320
            let consumer = Task { () async throws -> [Span] in
                var out: [Span] = []
                while let delivery = try await queue.receive() {
                    out.append(delivery.element)
                    try await Task.sleep(nanoseconds: 200_000)
                }
                return out
            }
            var dropped: [Span] = []
            var start: Int64 = 0
            while start < total {
                let range = Span(start: start, end: min(start + frame, total))
                if case .dropped = try await queue.send(range) { dropped.append(range) }
                start = range.end
            }
            await queue.close()
            let delivered = try await consumer.value
            #expect(zip(delivered, delivered.dropFirst()).allSatisfy { $0.end <= $1.start }, "FIFO by start sample")
            let all = (delivered + dropped).sorted { $0.start < $1.start }
            #expect(all.first?.start == 0 && all.last?.end == total)
            #expect(zip(all, all.dropFirst()).allSatisfy { $0.end == $1.start }, "delivered ∪ dropped tiles [0, N) once")
            let deliveredSamples = delivered.reduce(Int64(0)) { $0 + $1.end - $1.start }
            let droppedSamples = dropped.reduce(Int64(0)) { $0 + $1.end - $1.start }
            #expect(deliveredSamples + droppedSamples == total)
            if policy == .block { #expect(droppedSamples == 0) }
        }
    }
}
