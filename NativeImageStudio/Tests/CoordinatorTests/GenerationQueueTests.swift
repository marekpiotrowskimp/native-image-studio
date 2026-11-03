import Application
import Foundation
import Testing

@Suite("Generation queue")
struct GenerationQueueTests {
    @Test func fifoWithinPriority() {
        var q = GenerationQueue()
        let ids = (0..<4).map { _ in UUID() }
        ids.forEach { q.enqueue($0) }
        #expect(q.orderedIDs == ids)
        #expect(q.dequeue() == ids[0])
        #expect(q.count == 3)
    }

    @Test func higherPriorityFirstButStableFIFO() {
        var q = GenerationQueue()
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        q.enqueue(a)
        q.enqueue(b, priority: .low)
        q.enqueue(c, priority: .high)
        q.enqueue(d, priority: .high)
        #expect(q.orderedIDs == [c, d, a, b])
    }

    @Test func changingPriorityReorders() {
        var q = GenerationQueue()
        let a = UUID(), b = UUID(), c = UUID()
        [a, b, c].forEach { q.enqueue($0) }
        q.setPriority(c, .high)
        #expect(q.orderedIDs == [c, a, b])
        q.setPriority(c, .normal)
        // Back to its original FIFO slot.
        #expect(q.orderedIDs == [a, b, c])
    }

    @Test func removeAndDuplicates() {
        var q = GenerationQueue()
        let a = UUID(), b = UUID()
        q.enqueue(a)
        q.enqueue(a)
        q.enqueue(b)
        #expect(q.count == 2)
        let removedFirst = q.remove(a)
        let removedAgain = q.remove(a)
        let removedB = q.removeAll { $0 == b }
        #expect(removedFirst)
        #expect(!removedAgain)
        #expect(removedB == [b])
        #expect(q.isEmpty)
        let next = q.dequeue()
        #expect(next == nil)
    }
}

@Suite("Progress throttling")
struct ProgressThrottlerTests {
    @Test func limitsRateButKeepsFinal() {
        var t = ProgressThrottler(maxUpdatesPerSecond: 4)
        let start = ContinuousClock.now
        let results = [
            t.shouldEmit(isFinal: false, now: start),
            t.shouldEmit(isFinal: false, now: start + .milliseconds(100)),
            t.shouldEmit(isFinal: false, now: start + .milliseconds(260)),
            t.shouldEmit(isFinal: true, now: start + .milliseconds(270)),
        ]
        #expect(results == [true, false, true, true])
    }
}
