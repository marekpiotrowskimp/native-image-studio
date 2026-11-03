import Foundation

/// Lets through at most one update per `interval`, but always the first and the final one.
public struct ProgressThrottler: Sendable {
    public let interval: Duration
    private var last: ContinuousClock.Instant?

    public init(maxUpdatesPerSecond: Double = 4) {
        interval = .milliseconds(Int(1000 / max(0.1, maxUpdatesPerSecond)))
    }

    public mutating func shouldEmit(isFinal: Bool, now: ContinuousClock.Instant = .now) -> Bool {
        if isFinal || last == nil || now - last! >= interval {
            last = now
            return true
        }
        return false
    }
}
