import Application
import Domain
import Foundation
import Observation

/// Main-actor mirror of the coordinator state for SwiftUI. Updates arrive already
/// throttled by the coordinator (a few per second).
@MainActor
@Observable
public final class JobsStore {
    public private(set) var jobs: [UUID: JobSnapshot] = [:]
    public private(set) var queueOrder: [UUID] = []
    /// Called once per job when it completes (gallery import).
    public var onCompleted: ((GeneratedImage) -> Void)?

    private let services: AppServices
    private var listener: Task<Void, Never>?

    public init(services: AppServices) {
        self.services = services
    }

    public func start() {
        guard listener == nil else { return }
        let coordinator = services.coordinator
        listener = Task { [weak self] in
            let stream = await coordinator.events()
            for await event in stream {
                self?.apply(event)
            }
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    func apply(_ event: CoordinatorEvent) {
        switch event {
        case .jobUpdated(let job):
            let previous = jobs[job.id]?.state
            jobs[job.id] = job
            if case .completed(let image) = job.state, previous != job.state {
                onCompleted?(image)
            }
        case .queueChanged(let order):
            queueOrder = order
        }
    }

    // MARK: Queries

    public var sortedJobs: [JobSnapshot] {
        jobs.values.sorted { $0.enqueuedAt > $1.enqueuedAt }
    }

    public var activeJob: JobSnapshot? {
        jobs.values.first {
            switch $0.state {
            case .loading, .running: true
            default: false
            }
        }
    }

    public var queuedJobs: [JobSnapshot] { queueOrder.compactMap { jobs[$0] } }

    public func job(_ id: UUID?) -> JobSnapshot? { id.flatMap { jobs[$0] } }

    public func batchProgress(_ batchID: UUID) -> BatchProgress {
        let members = jobs.values.filter { $0.batchID == batchID }
        var p = BatchProgress(batchID: batchID, total: members.count, completed: 0, failed: 0,
                              cancelled: 0, running: 0, queued: 0, currentJobFraction: 0)
        for j in members {
            switch j.state {
            case .queued: p.queued += 1
            case .loading: p.running += 1
            case .running(let s, let t):
                p.running += 1
                p.currentJobFraction = t > 0 ? Double(s) / Double(t) : 0
            case .completed: p.completed += 1
            case .failed: p.failed += 1
            case .cancelled: p.cancelled += 1
            }
        }
        return p
    }

    // MARK: Commands

    public func cancel(_ id: UUID) {
        let coordinator = services.coordinator
        Task { await coordinator.cancel(id) }
    }

    public func cancelBatch(_ batchID: UUID) {
        let batches = services.batches
        Task { await batches.cancelBatch(batchID) }
    }

    public func setPriority(_ id: UUID, _ priority: JobPriority) {
        let coordinator = services.coordinator
        Task { await coordinator.setPriority(id, priority) }
    }

    public func clearFinished() {
        jobs = jobs.filter { !$0.value.state.isTerminal }
    }
}

public extension JobState {
    /// 0…1 progress for progress bars.
    var fraction: Double {
        switch self {
        case .queued: 0
        case .loading: 0.02
        case .running(let s, let t): t > 0 ? max(0.02, Double(s) / Double(t)) : 0.02
        case .completed, .failed, .cancelled: 1
        }
    }

    var polishLabel: String {
        switch self {
        case .queued: "W kolejce"
        case .loading: "Ładowanie modelu"
        case .running(let s, let t): s == 0 ? "Przygotowanie" : "Krok \(s)/\(t)"
        case .completed: "Gotowe"
        case .cancelled: "Anulowano"
        case .failed: "Błąd"
        }
    }
}
