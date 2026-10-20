import BenchmarkSupport
import Foundation

public enum QueueError: Error, Equatable, CustomStringConvertible {
    case closed
    case failed(String)

    public var description: String {
        switch self {
        case .closed: return "queue is closed"
        case .failed(let reason): return "queue failed: \(reason)"
        }
    }
}

/// Bounded FIFO channel between one replay producer and one pipeline consumer (plan C2).
///
/// - `block`: a full queue suspends the sender (FIFO among senders) until a
///   receive frees a slot; the element is admitted at that moment.
/// - `drop_newest`: a full queue rejects the offered element and reports it;
///   nothing already queued is touched. No other drop policy exists in v1.
///
/// Admission and dequeue instants are stamped inside the actor with the run
/// clock at the moment they actually happen. Every suspended continuation is
/// resumed exactly once: by admission/delivery, by `close`/`fail`, or by
/// cancellation (which first removes the waiter from its list).
public actor BoundedQueue<Element: Sendable> {
    public enum Admission: Sendable, Equatable {
        /// `entryNS` is the admission instant; `blocked` is true when the sender waited for space.
        case accepted(entryNS: Int64, depthAfter: Int, blocked: Bool)
        case dropped(depth: Int)
    }

    public struct Delivery: Sendable {
        public let element: Element
        public let entryNS: Int64
        public let dequeueNS: Int64
        public let depthAfter: Int
    }

    private struct Slot {
        let element: Element
        let entryNS: Int64
    }

    private struct BlockedSender {
        let id: UInt64
        let element: Element
        let continuation: CheckedContinuation<Admission, Error>
    }

    private struct WaitingReceiver {
        let id: UInt64
        let continuation: CheckedContinuation<Delivery?, Error>
    }

    public nonisolated let capacity: Int
    public nonisolated let policy: OverflowPolicy
    private let clock: any RunClock

    private var slots: [Slot] = []
    private var head = 0
    private var senders: [BlockedSender] = []
    private var receivers: [WaitingReceiver] = []
    private var nextID: UInt64 = 0
    private var isClosed = false
    private var failure: QueueError?
    public private(set) var maxDepth = 0
    public private(set) var acceptedCount = 0
    public private(set) var droppedCount = 0
    public private(set) var blockedCount = 0

    public init(capacity: Int, policy: OverflowPolicy, clock: any RunClock) {
        precondition(capacity >= 1, "capacity must be positive")
        self.capacity = capacity
        self.policy = policy
        self.clock = clock
    }

    public var depth: Int { slots.count - head }

    // MARK: Sending

    public func send(_ element: Element) async throws -> Admission {
        if let failure { throw failure }
        if isClosed { throw QueueError.closed }
        try Task.checkCancellation()

        if let receiver = popReceiver() {
            // Empty queue with a waiting consumer: admit and deliver in the same instant.
            let now = clock.nowNS()
            acceptedCount += 1
            maxDepth = max(maxDepth, 1)
            receiver.continuation.resume(returning: Delivery(element: element, entryNS: now, dequeueNS: now, depthAfter: 0))
            return .accepted(entryNS: now, depthAfter: 0, blocked: false)
        }
        if depth < capacity {
            return admit(element, blocked: false)
        }
        switch policy {
        case .dropNewest:
            droppedCount += 1
            return .dropped(depth: depth)
        case .block:
            blockedCount += 1
            let id = makeID()
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    senders.append(BlockedSender(id: id, element: element, continuation: continuation))
                }
            } onCancel: {
                Task { await self.cancelSender(id) }
            }
        }
    }

    private func admit(_ element: Element, blocked: Bool) -> Admission {
        let now = clock.nowNS()
        slots.append(Slot(element: element, entryNS: now))
        acceptedCount += 1
        maxDepth = max(maxDepth, depth)
        return .accepted(entryNS: now, depthAfter: depth, blocked: blocked)
    }

    // MARK: Receiving

    /// Next element in FIFO order, or nil once the queue is closed and drained.
    public func receive() async throws -> Delivery? {
        if let failure { throw failure }
        try Task.checkCancellation()
        if depth > 0 { return dequeue() }
        if isClosed { return nil }
        let id = makeID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                receivers.append(WaitingReceiver(id: id, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelReceiver(id) }
        }
    }

    /// Dequeues up to `limit` already-queued elements without suspending (batch
    /// draining for writers). Blocked senders are admitted as slots open, exactly
    /// as with `receive()`.
    public func receiveAvailable(limit: Int) throws -> [Delivery] {
        if let failure { throw failure }
        var batch: [Delivery] = []
        while batch.count < limit, depth > 0 { batch.append(dequeue()) }
        return batch
    }

    private func dequeue() -> Delivery {
        let slot = slots[head]
        head += 1
        if head > 64, head * 2 > slots.count {
            slots.removeFirst(head)
            head = 0
        }
        let now = clock.nowNS()
        // A slot opened: admit the oldest blocked sender at this instant.
        if !senders.isEmpty {
            let sender = senders.removeFirst()
            sender.continuation.resume(returning: admit(sender.element, blocked: true))
        }
        return Delivery(element: slot.element, entryNS: slot.entryNS, dequeueNS: now, depthAfter: depth)
    }

    // MARK: Lifecycle

    /// No further sends; receivers drain what is queued, then get nil.
    public func close() {
        guard !isClosed, failure == nil else { return }
        isClosed = true
        for sender in senders { sender.continuation.resume(throwing: QueueError.closed) }
        senders.removeAll()
        if depth == 0 {
            for receiver in receivers { receiver.continuation.resume(returning: nil) }
            receivers.removeAll()
        }
    }

    /// Fails the queue: every waiter and every later call throws.
    public func fail(_ reason: String) {
        guard failure == nil else { return }
        let error = QueueError.failed(reason)
        failure = error
        for sender in senders { sender.continuation.resume(throwing: error) }
        for receiver in receivers { receiver.continuation.resume(throwing: error) }
        senders.removeAll()
        receivers.removeAll()
    }

    // MARK: Cancellation

    private func cancelSender(_ id: UInt64) {
        guard let index = senders.firstIndex(where: { $0.id == id }) else { return } // already resumed
        senders.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func cancelReceiver(_ id: UInt64) {
        guard let index = receivers.firstIndex(where: { $0.id == id }) else { return }
        receivers.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func popReceiver() -> WaitingReceiver? {
        receivers.isEmpty ? nil : receivers.removeFirst()
    }

    private func makeID() -> UInt64 {
        nextID += 1
        return nextID
    }

    /// Test/diagnostic view of waiters.
    public var waitingSenders: Int { senders.count }
    public var waitingReceivers: Int { receivers.count }

    /// Structural invariants; an empty result means the queue state is consistent.
    public var invariantViolations: [String] {
        var problems: [String] = []
        if depth < 0 || depth > capacity { problems.append("depth \(depth) outside 0...\(capacity)") }
        if !senders.isEmpty && depth != capacity { problems.append("\(senders.count) blocked senders while depth \(depth) < capacity") }
        if !receivers.isEmpty && depth != 0 { problems.append("\(receivers.count) waiting receivers while depth \(depth) > 0") }
        if !senders.isEmpty && policy == .dropNewest { problems.append("drop_newest queue has blocked senders") }
        if isClosed && !senders.isEmpty { problems.append("closed queue still has blocked senders") }
        if isClosed && depth == 0 && !receivers.isEmpty { problems.append("closed, drained queue still has waiting receivers") }
        if failure != nil && (!senders.isEmpty || !receivers.isEmpty) { problems.append("failed queue still has waiters") }
        if maxDepth > capacity { problems.append("maxDepth \(maxDepth) exceeded capacity \(capacity)") }
        return problems
    }
}
