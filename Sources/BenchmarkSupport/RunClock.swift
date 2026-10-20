import Foundation
import os

/// Run-relative monotonic execution clock (plan D1/D3).
///
/// `nowNS()` is integer nanoseconds since one process-local origin. Every real
/// execution timestamp in a run comes from the same instance, so no two clock
/// domains are ever subtracted. Step-mode virtual time is a separate service
/// (`VirtualClock` in Replay) and never flows through this protocol.
public protocol RunClock: Sendable {
    func nowNS() -> Int64
    /// Sleeps until the absolute run-relative deadline; returns immediately if it already passed.
    func sleep(untilNS deadline: Int64) async throws
}

/// Checked conversion of `Swift.Duration` to integer nanoseconds.
///
/// Uses the integer `(seconds, attoseconds)` components; sub-nanosecond
/// remainders are truncated toward zero. No floating-point seconds are used.
public enum DurationNS {
    public static func nanoseconds(_ duration: Duration) throws -> Int64 {
        let (seconds, attoseconds) = duration.components
        let wholeNS = try CheckedMath.multiply(seconds, 1_000_000_000)
        return try CheckedMath.add(wholeNS, attoseconds / 1_000_000_000)
    }
}

/// `ContinuousClock`-backed run clock. Continuous time keeps advancing while
/// the machine sleeps, which is the conservative choice for wall pacing.
public final class ContinuousRunClock: RunClock {
    public let origin: ContinuousClock.Instant
    private let clock = ContinuousClock()

    public init() { origin = clock.now }

    public func nowNS() -> Int64 {
        // A run would need ~292 years to overflow int64 nanoseconds.
        (try? DurationNS.nanoseconds(origin.duration(to: clock.now))) ?? Int64.max
    }

    public func sleep(untilNS deadline: Int64) async throws {
        try Task.checkCancellation()
        let target = origin.advanced(by: .nanoseconds(deadline))
        if target <= clock.now { return }
        try await clock.sleep(until: target, tolerance: nil)
    }

    /// The clock's advertised minimum resolution; a capability, not an accuracy guarantee.
    public var minimumResolutionNS: Int64 {
        (try? DurationNS.nanoseconds(clock.minimumResolution)) ?? -1
    }
}

/// Deterministic test clock: time moves only when advanced or slept on.
///
/// `sleep(untilNS:)` jumps time forward to the deadline and records the call,
/// so real/accelerated scheduling logic can be checked for exact deadlines
/// without relying on host scheduling.
public final class FakeRunClock: RunClock {
    private struct State {
        var now: Int64
        var sleeps: [Int64] = []
        var stepPerRead: Int64
    }

    private let state: OSAllocatedUnfairLock<State>

    /// - parameter stepPerRead: optional nanoseconds added after every `nowNS()` read,
    ///   to model execution cost between observations.
    public init(startNS: Int64 = 0, stepPerRead: Int64 = 0) {
        state = OSAllocatedUnfairLock(initialState: State(now: startNS, stepPerRead: stepPerRead))
    }

    public func nowNS() -> Int64 {
        state.withLock { state in
            let value = state.now
            state.now += state.stepPerRead
            return value
        }
    }

    public func sleep(untilNS deadline: Int64) async throws {
        try Task.checkCancellation()
        state.withLock { state in
            state.sleeps.append(deadline)
            state.now = max(state.now, deadline)
        }
        await Task.yield()
    }

    public func advance(byNS delta: Int64) {
        state.withLock { $0.now += delta }
    }

    public var recordedSleeps: [Int64] { state.withLock { $0.sleeps } }
}
