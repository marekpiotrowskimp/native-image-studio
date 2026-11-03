import Foundation
import Synchronization

/// Thread-safe one-way cancellation flag shared between an engine actor, a stream's
/// `onTermination` and the inference loop (which polls it between steps).
public final class CancellationFlag: Sendable {
    private let state = Mutex(false)

    public init() {}

    public var isCancelled: Bool { state.withLock { $0 } }
    public func cancel() { state.withLock { $0 = true } }
}

/// Collects step timestamps reported from an inference thread.
public final class StepTimes: Sendable {
    private struct Mark { let step: Int; let at: ContinuousClock.Instant }
    private let state = Mutex<(first: Mark?, last: Mark?)>((nil, nil))

    public init() {}

    public func record(_ step: Int, at instant: ContinuousClock.Instant = .now) {
        state.withLock {
            if $0.first == nil { $0.first = Mark(step: step, at: instant) }
            $0.last = Mark(step: step, at: instant)
        }
    }

    /// Highest step reported.
    public var count: Int { state.withLock { $0.last?.step ?? 0 } }

    /// Mean time per step between the first and last reported step (excludes the
    /// work before the first step, e.g. text encoding, and after the last, e.g. decode).
    public var secondsPerStep: Double? {
        state.withLock { s in
            guard let first = s.first, let last = s.last, last.step > first.step else { return nil }
            return (last.at - first.at).seconds / Double(last.step - first.step)
        }
    }
}

public extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
