import BenchmarkSupport
import Foundation
import Replay
import Testing

/// V11 (unit level): bounded FIFO, blocking/drop accounting, close/fail/cancel safety.
struct BoundedQueueTests {
    @Test func fifoOrderAndStamps() async throws {
        let clock = FakeRunClock(startNS: 10, stepPerRead: 1)
        let queue = BoundedQueue<Int>(capacity: 4, policy: .block, clock: clock)
        for value in 0..<4 { _ = try await queue.send(value) }
        await queue.close()
        var received: [Int] = []
        while let delivery = try await queue.receive() {
            #expect(delivery.dequeueNS >= delivery.entryNS)
            received.append(delivery.element)
        }
        #expect(received == [0, 1, 2, 3])
        #expect(try await queue.receive() == nil, "closed and drained stays nil")
    }

    @Test func blockPolicyNeverExceedsCapacityUnderSlowConsumer() async throws {
        let queue = BoundedQueue<Int>(capacity: 3, policy: .block, clock: ContinuousRunClock())
        let producer = Task {
            var blocked = 0
            for value in 0..<200 {
                if case .accepted(_, _, true) = try await queue.send(value) { blocked += 1 }
            }
            await queue.close()
            return blocked
        }
        var received: [Int] = []
        while let delivery = try await queue.receive() {
            received.append(delivery.element)
            if delivery.element % 20 == 0 { try await Task.sleep(nanoseconds: 1_000_000) }
        }
        let blocked = try await producer.value
        #expect(received == Array(0..<200), "lossless and ordered")
        #expect(await queue.maxDepth <= 3)
        #expect(blocked > 0, "a faster producer must have experienced backpressure")
        #expect(await queue.droppedCount == 0)
    }

    @Test func dropNewestRejectsOfferedElementOnly() async throws {
        let queue = BoundedQueue<Int>(capacity: 2, policy: .dropNewest, clock: FakeRunClock())
        var outcomes: [Bool] = []
        for value in 0..<5 {
            if case .accepted = try await queue.send(value) { outcomes.append(true) } else { outcomes.append(false) }
        }
        #expect(outcomes == [true, true, false, false, false])
        await queue.close()
        var received: [Int] = []
        while let delivery = try await queue.receive() { received.append(delivery.element) }
        #expect(received == [0, 1], "queued elements are untouched; the newest offers are dropped")
        #expect(await queue.droppedCount == 3)
    }

    @Test func handoffToWaitingReceiver() async throws {
        let queue = BoundedQueue<String>(capacity: 1, policy: .block, clock: FakeRunClock())
        let receiver = Task { try await queue.receive()?.element }
        while await queue.waitingReceivers == 0 { await Task.yield() }
        _ = try await queue.send("x")
        #expect(try await receiver.value == "x")
    }

    @Test func closeWakesWaitingReceiverWithNil() async throws {
        let queue = BoundedQueue<Int>(capacity: 1, policy: .block, clock: FakeRunClock())
        let receiver = Task { try await queue.receive() }
        while await queue.waitingReceivers == 0 { await Task.yield() }
        await queue.close()
        #expect(try await receiver.value == nil)
        await #expect(throws: QueueError.closed) { _ = try await queue.send(1) }
    }

    @Test func failWakesBlockedSenderAndReceiver() async throws {
        let queue = BoundedQueue<Int>(capacity: 1, policy: .block, clock: FakeRunClock())
        _ = try await queue.send(0)
        let sender = Task { try await queue.send(1) }
        while await queue.waitingSenders == 0 { await Task.yield() }
        await queue.fail("recorder failed")
        await #expect(throws: QueueError.failed("recorder failed")) { _ = try await sender.value }
        await #expect(throws: QueueError.failed("recorder failed")) { _ = try await queue.receive() }

        let empty = BoundedQueue<Int>(capacity: 1, policy: .block, clock: FakeRunClock())
        let receiver = Task { try await empty.receive() }
        while await empty.waitingReceivers == 0 { await Task.yield() }
        await empty.fail("adapter failed")
        await #expect(throws: QueueError.failed("adapter failed")) { _ = try await receiver.value }
    }

    @Test func cancelledBlockedSenderIsRemovedAndNotAdmitted() async throws {
        let queue = BoundedQueue<Int>(capacity: 1, policy: .block, clock: FakeRunClock())
        _ = try await queue.send(0)
        let sender = Task { try await queue.send(1) }
        while await queue.waitingSenders == 0 { await Task.yield() }
        sender.cancel()
        await #expect(throws: CancellationError.self) { _ = try await sender.value }
        #expect(await queue.waitingSenders == 0)
        await queue.close()
        var received: [Int] = []
        while let delivery = try await queue.receive() { received.append(delivery.element) }
        #expect(received == [0], "a cancelled offer never reaches the consumer")
    }

    @Test func cancelledReceiverIsRemoved() async throws {
        let queue = BoundedQueue<Int>(capacity: 1, policy: .block, clock: FakeRunClock())
        let receiver = Task { try await queue.receive() }
        while await queue.waitingReceivers == 0 { await Task.yield() }
        receiver.cancel()
        await #expect(throws: CancellationError.self) { _ = try await receiver.value }
        #expect(await queue.waitingReceivers == 0)
        _ = try await queue.send(7)
        #expect(try await queue.receive()?.element == 7, "element is not lost to the cancelled receiver")
    }

    /// Races cancellation against admission many times; each waiter must resume exactly once
    /// (a double resume traps the process, a lost resume hangs the test).
    @Test func cancellationRacesNeverDoubleOrLoseResume() async throws {
        for round in 0..<300 {
            let queue = BoundedQueue<Int>(capacity: 1, policy: .block, clock: FakeRunClock())
            _ = try await queue.send(-1)
            let sender = Task { try await queue.send(round) }
            if round % 2 == 0 { await Task.yield() }
            async let drained = queue.receive()
            sender.cancel()
            _ = try await drained
            let outcome = await sender.result
            await queue.close()
            var rest: [Int] = []
            while let delivery = try await queue.receive() { rest.append(delivery.element) }
            switch outcome {
            case .success: #expect(rest == [round], "admitted offer must be delivered")
            case .failure: #expect(rest.isEmpty, "cancelled offer must not be delivered")
            }
        }
    }
}
