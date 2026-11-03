import Foundation

public enum JobPriority: Int, Sendable, Comparable, Codable, CaseIterable {
    case low = 0
    case normal = 1
    case high = 2

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Pending jobs: FIFO within a priority level, higher priority first.
/// Pure value type so ordering rules are unit-testable in isolation.
public struct GenerationQueue: Sendable, Equatable {
    private struct Entry: Sendable, Equatable {
        let id: UUID
        var priority: JobPriority
        let sequence: UInt64
    }

    private var entries: [Entry] = []
    private var nextSequence: UInt64 = 0

    public init() {}

    public var isEmpty: Bool { entries.isEmpty }
    public var count: Int { entries.count }

    /// IDs in the order they will run.
    public var orderedIDs: [UUID] { entries.map(\.id) }

    public func contains(_ id: UUID) -> Bool { entries.contains { $0.id == id } }

    public mutating func enqueue(_ id: UUID, priority: JobPriority = .normal) {
        guard !contains(id) else { return }
        entries.append(Entry(id: id, priority: priority, sequence: nextSequence))
        nextSequence += 1
        sort()
    }

    public mutating func dequeue() -> UUID? {
        entries.isEmpty ? nil : entries.removeFirst().id
    }

    @discardableResult
    public mutating func remove(_ id: UUID) -> Bool {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return false }
        entries.remove(at: i)
        return true
    }

    @discardableResult
    public mutating func removeAll(where predicate: (UUID) -> Bool) -> [UUID] {
        let removed = entries.filter { predicate($0.id) }.map(\.id)
        entries.removeAll { predicate($0.id) }
        return removed
    }

    /// Change priority; the job keeps its original FIFO position within the new level.
    public mutating func setPriority(_ id: UUID, _ priority: JobPriority) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].priority = priority
        sort()
    }

    private mutating func sort() {
        entries.sort { a, b in
            a.priority != b.priority ? a.priority > b.priority : a.sequence < b.sequence
        }
    }
}
