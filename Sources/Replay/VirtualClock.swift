import Foundation

/// Step-mode logical time (plan C2). Separate from `RunClock` by type, so a
/// virtual instant can never be subtracted from a real one or published as
/// live latency. It only moves forward, and only when the coordinator (or a
/// configured mock delay, from M3) advances it; nothing sleeps.
public actor VirtualClock {
    public private(set) var nowNS: Int64 = 0

    public init() {}

    /// Advances to `max(now, deadline)` and returns the new time.
    @discardableResult
    public func advance(to deadline: Int64) -> Int64 {
        nowNS = max(nowNS, deadline)
        return nowNS
    }

    @discardableResult
    public func advance(byNS delta: Int64) -> Int64 {
        precondition(delta >= 0, "virtual time never moves backwards")
        nowNS += delta
        return nowNS
    }
}
