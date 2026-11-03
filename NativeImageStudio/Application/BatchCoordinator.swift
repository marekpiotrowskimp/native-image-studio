import Domain
import Foundation

/// Aggregate state of a batch.
public struct BatchProgress: Sendable, Equatable {
    public let batchID: UUID
    public var total: Int
    public var completed: Int
    public var failed: Int
    public var cancelled: Int
    public var running: Int
    public var queued: Int
    /// 0...1 within the currently running job.
    public var currentJobFraction: Double

    public init(batchID: UUID, total: Int, completed: Int, failed: Int, cancelled: Int,
                running: Int, queued: Int, currentJobFraction: Double) {
        self.batchID = batchID
        self.total = total
        self.completed = completed
        self.failed = failed
        self.cancelled = cancelled
        self.running = running
        self.queued = queued
        self.currentJobFraction = currentJobFraction
    }

    public var finished: Int { completed + failed + cancelled }
    public var isFinished: Bool { finished == total }
    public var fractionComplete: Double {
        total == 0 ? 1 : min(1, (Double(finished) + currentJobFraction) / Double(total))
    }
}

/// A file that could not be turned into a job (e.g. unreadable); counts as failed.
public struct BatchSubmissionFailure: Sendable, Equatable {
    public let fileURL: URL
    public let message: String
}

/// Fans one prompt + settings out over many photos. Each photo is its own job sharing
/// a batch ID; a failure of one job does not stop the others, cancelling the batch
/// cancels all of them. The model is not reloaded between photos because consecutive
/// jobs target the same model.
public actor BatchCoordinator {
    private let coordinator: GenerationCoordinator
    private var members: [UUID: [UUID]] = [:]
    private var submissionFailures: [UUID: [BatchSubmissionFailure]] = [:]

    public init(coordinator: GenerationCoordinator) {
        self.coordinator = coordinator
    }

    /// - Parameters:
    ///   - template: prompt/mode/settings; its input images are replaced per photo.
    ///   - inputs: photos, each becomes the primary image of one job.
    ///   - sizing: output size for a photo (e.g. its aspect ratio on the model grid);
    ///     nil keeps the template size.
    public func submitBatch(
        template: GenerationRequest,
        inputs: [URL],
        priority: JobPriority = .normal,
        sizing: (@Sendable (URL) -> (width: Int, height: Int)?)? = nil
    ) async -> UUID {
        let batchID = UUID()
        members[batchID] = []
        submissionFailures[batchID] = []
        for url in inputs {
            let size = sizing?(url)
            let request = template.with(
                inputImages: [InputImage(sourceURL: url, role: .primary)],
                batchID: .some(batchID),
                width: size?.width,
                height: size?.height
            )
            do {
                let id = try await coordinator.submit(request, priority: priority)
                members[batchID, default: []].append(id)
            } catch {
                let message = (error as? any LocalizedError)?.errorDescription ?? String(describing: error)
                submissionFailures[batchID, default: []].append(BatchSubmissionFailure(fileURL: url, message: message))
            }
        }
        return batchID
    }

    public func cancelBatch(_ batchID: UUID) async {
        await coordinator.cancelBatch(batchID)
    }

    public func failures(_ batchID: UUID) -> [BatchSubmissionFailure] {
        submissionFailures[batchID] ?? []
    }

    public func jobIDs(_ batchID: UUID) -> [UUID] {
        members[batchID] ?? []
    }

    public func progress(_ batchID: UUID) async -> BatchProgress {
        let jobs = await coordinator.jobs(inBatch: batchID)
        let failedAtSubmit = submissionFailures[batchID]?.count ?? 0
        var p = BatchProgress(
            batchID: batchID, total: jobs.count + failedAtSubmit, completed: 0,
            failed: failedAtSubmit, cancelled: 0, running: 0, queued: 0, currentJobFraction: 0)
        for job in jobs {
            switch job.state {
            case .queued: p.queued += 1
            case .loading: p.running += 1
            case .running(let step, let total):
                p.running += 1
                p.currentJobFraction = total > 0 ? Double(step) / Double(total) : 0
            case .completed: p.completed += 1
            case .cancelled: p.cancelled += 1
            case .failed: p.failed += 1
            }
        }
        return p
    }

    /// Suspends until every job of the batch is terminal.
    public func waitForBatch(_ batchID: UUID) async -> BatchProgress {
        for id in members[batchID] ?? [] {
            _ = await coordinator.waitForCompletion(id)
        }
        return await progress(batchID)
    }
}
