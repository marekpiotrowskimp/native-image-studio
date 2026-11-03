import Domain
import Foundation
import Infrastructure

/// Observable state of one job.
public struct JobSnapshot: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let request: GenerationRequest
    public var state: JobState
    public var priority: JobPriority
    public let enqueuedAt: Date
    public var startedAt: Date?
    public var finishedAt: Date?
    public var warnings: [String]
    /// Shown while the model loads, e.g. that the system is compiling it for the Neural Engine.
    public var loadingNote: String? = nil
    /// Latest intermediate image while running; dropped when the job ends.
    public var preview: PreviewFrame? = nil

    public var batchID: UUID? { request.batchID }
}

public enum CoordinatorEvent: Sendable, Equatable {
    case jobUpdated(JobSnapshot)
    case queueChanged([UUID])
}

/// Serializes GPU work: one active generation, the rest in a priority FIFO.
///
/// Lifecycle per job: Queued → Loading → Running → Completed | Cancelled | Failed.
/// A running job is only marked Cancelled after the engine's stream finished with
/// `GenerationError.cancelled`, i.e. the engine reached a safe stop point.
public actor GenerationCoordinator {
    private let registry: EngineRegistry
    private let models: ModelRepository
    private let memory: MemoryBudgetManager
    private let validator: RequestValidator
    private let maxUpdatesPerSecond: Double
    private let memorySettleTimeout: Duration

    private var jobs: [UUID: JobSnapshot] = [:]
    private var queue = GenerationQueue()
    private var activeJobID: UUID?
    private var activeEngine: (any ImageGenerationEngine)?
    private var cancelRequested: Set<UUID> = []
    private var runner: Task<Void, Never>?
    private var subscribers: [UUID: AsyncStream<CoordinatorEvent>.Continuation] = [:]
    private var waiters: [UUID: [CheckedContinuation<JobState, Never>]] = [:]
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var residents: [any GPUResident] = []
    /// While > 0 no job starts: someone else (the prompt assistant) owns the GPU.
    private var exclusiveHolders = 0

    public init(
        registry: EngineRegistry,
        models: ModelRepository,
        memory: MemoryBudgetManager,
        validator: RequestValidator = RequestValidator(),
        maxUpdatesPerSecond: Double = 4,
        memorySettleTimeout: Duration = .seconds(5)
    ) {
        self.registry = registry
        self.models = models
        self.memory = memory
        self.validator = validator
        self.maxUpdatesPerSecond = maxUpdatesPerSecond
        self.memorySettleTimeout = memorySettleTimeout
    }

    // MARK: Observation

    public func events() -> AsyncStream<CoordinatorEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: CoordinatorEvent.self, bufferingPolicy: .bufferingNewest(256))
        let token = UUID()
        subscribers[token] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(token) }
        }
        return stream
    }

    private func removeSubscriber(_ token: UUID) {
        subscribers[token] = nil
    }

    public func snapshot(_ id: UUID) -> JobSnapshot? { jobs[id] }

    public func allJobs() -> [JobSnapshot] {
        jobs.values.sorted { $0.enqueuedAt < $1.enqueuedAt }
    }

    public func jobs(inBatch batchID: UUID) -> [JobSnapshot] {
        allJobs().filter { $0.batchID == batchID }
    }

    public var queuedIDs: [UUID] { queue.orderedIDs }
    /// A job is running or waiting.
    public var isBusy: Bool { runner != nil || !queue.isEmpty }
    public var activeID: UUID? { activeJobID }

    // MARK: Commands

    /// Validates against the model's capabilities and enqueues. Throws on invalid requests.
    @discardableResult
    public func submit(_ request: GenerationRequest, priority: JobPriority = .normal) async throws -> UUID {
        let model = try await models.descriptor(id: request.modelID)
        let caps = try await registry.capabilities(for: model)
        try validator.validate(request, capabilities: caps)

        let job = JobSnapshot(
            id: request.id, request: request, state: .queued, priority: priority,
            enqueuedAt: Date(), startedAt: nil, finishedAt: nil, warnings: [])
        jobs[job.id] = job
        queue.enqueue(job.id, priority: priority)
        emit(.jobUpdated(job))
        emit(.queueChanged(queue.orderedIDs))
        startIfIdle()
        return job.id
    }

    public func setPriority(_ id: UUID, _ priority: JobPriority) {
        guard var job = jobs[id], job.state == .queued else { return }
        job.priority = priority
        jobs[id] = job
        queue.setPriority(id, priority)
        emit(.jobUpdated(job))
        emit(.queueChanged(queue.orderedIDs))
    }

    /// Queued jobs are cancelled immediately; the running job is cancelled once the
    /// engine confirms a safe stop point.
    public func cancel(_ id: UUID) async {
        guard let job = jobs[id], !job.state.isTerminal else { return }
        if queue.remove(id) {
            finish(id, .cancelled)
            emit(.queueChanged(queue.orderedIDs))
            return
        }
        cancelRequested.insert(id)
        if activeJobID == id, let engine = activeEngine {
            await engine.cancel(requestID: id)
        }
    }

    public func cancelBatch(_ batchID: UUID) async {
        let ids = jobs.values.filter { $0.batchID == batchID && !$0.state.isTerminal }.map(\.id)
        // Drop queued members first so the queue cannot start one of them meanwhile.
        let removed = queue.removeAll { id in ids.contains(id) }
        for id in removed { finish(id, .cancelled) }
        if !removed.isEmpty { emit(.queueChanged(queue.orderedIDs)) }
        for id in ids where !removed.contains(id) { await cancel(id) }
    }

    /// Suspends until the job reaches a terminal state.
    public func waitForCompletion(_ id: UUID) async -> JobState {
        if let state = jobs[id]?.state, state.isTerminal { return state }
        guard jobs[id] != nil else { return .failed("Nieznane zadanie") }
        return await withCheckedContinuation { waiters[id, default: []].append($0) }
    }

    /// Suspends until the queue is empty and nothing runs.
    public func waitUntilIdle() async {
        if runner == nil && queue.isEmpty { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    // MARK: Execution

    // MARK: Sharing the GPU

    /// Registers a non-engine model holder that must be released before an image model loads.
    public func register(resident: any GPUResident) {
        residents.append(resident)
    }

    /// Runs `body` with the GPU to itself: waits until queued and running jobs finish, keeps new
    /// jobs queued meanwhile and unloads image models first, so an LLM and an image model never
    /// share 24 GB of unified memory.
    public func withExclusiveGPU<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        while runner != nil || !queue.isEmpty { await waitUntilIdle() }
        exclusiveHolders += 1
        defer {
            exclusiveHolders -= 1
            startIfIdle()
        }
        for engine in registry.all {
            guard let loaded = await engine.loadedModelID() else { continue }
            await StageLog.measure("unload \(loaded) (exclusive GPU)") { await engine.unloadModel() }
        }
        return try await body()
    }

    private func startIfIdle() {
        guard runner == nil, exclusiveHolders == 0, !queue.isEmpty else { return }
        runner = Task { await self.drain() }
    }

    private func drain() async {
        while let id = queue.dequeue() {
            emit(.queueChanged(queue.orderedIDs))
            await run(id)
        }
        runner = nil
        let waiting = idleWaiters
        idleWaiters.removeAll()
        waiting.forEach { $0.resume() }
    }

    private func run(_ id: UUID) async {
        guard let job = jobs[id], !job.state.isTerminal else { return }
        let request = job.request
        activeJobID = id
        StageLog.note("job \(id.uuidString.prefix(8)) \(request.modelID): dequeued after \(String(format: "%.2f", Date().timeIntervalSince(job.enqueuedAt))) s in queue")
        defer {
            activeJobID = nil
            activeEngine = nil
            cancelRequested.remove(id)
        }

        do {
            let model = try await models.descriptor(id: request.modelID)
            let engine = try registry.engine(for: model)
            activeEngine = engine
            update(id) { $0.state = .loading; $0.startedAt = Date() }

            try await ensureLoaded(model, on: engine, jobID: id)
            if cancelRequested.contains(id) { throw GenerationError.cancelled }

            switch await admit({ $0.admitJob(request, model: model, modelLoaded: true) }) {
            case .rejected(let error): throw error
            case .allowed(let warnings) where !warnings.isEmpty:
                update(id) { job in job.warnings += warnings.filter { !job.warnings.contains($0) } }
            case .allowed: break
            }

            var throttler = ProgressThrottler(maxUpdatesPerSecond: maxUpdatesPerSecond)
            StageLog.note("job \(id.uuidString.prefix(8)): generation submitted")
            let stream = try await engine.generate(request: request)
            var loggedFirstStep = false
            // A cancel may have arrived while `generate` was being set up.
            if cancelRequested.contains(id) { await engine.cancel(requestID: id) }
            var result: GeneratedImage?
            for try await event in stream {
                switch event {
                case .step(let current, let total):
                    if !loggedFirstStep {
                        loggedFirstStep = true
                        StageLog.note("job \(id.uuidString.prefix(8)): step \(current)/\(total)")
                    }
                    let emitNow = throttler.shouldEmit(isFinal: current == total)
                    update(id, emit: emitNow) { $0.state = .running(step: current, total: total) }
                case .preview(let frame):
                    update(id) { $0.preview = frame }
                case .completed(let image):
                    result = image
                case .preparing, .preprocessingInputs, .decoding:
                    if case .loading = jobs[id]?.state {
                        update(id) { $0.state = .running(step: 0, total: request.steps) }
                    }
                case .loadingModel:
                    update(id) { $0.state = .loading }
                }
            }
            if let result {
                finish(id, .completed(result))
            } else if cancelRequested.contains(id) {
                finish(id, .cancelled)
            } else {
                finish(id, .failed("Silnik zakończył bez wyniku."))
            }
        } catch let error as GenerationError where error == .cancelled {
            finish(id, .cancelled)
        } catch is CancellationError {
            finish(id, .cancelled)
        } catch {
            finish(id, .failed(Self.message(for: error)))
        }
    }

    /// Model switch procedure: stop other engines' work, unload (release refs, sync GPU,
    /// clear caches inside the engine), admit by memory budget, then load.
    private func ensureLoaded(_ model: ModelDescriptor, on engine: any ImageGenerationEngine, jobID: UUID) async throws {
        if await engine.loadedModelID() == model.id { return }

        for other in registry.all {
            guard let loaded = await other.loadedModelID() else { continue }
            await StageLog.measure("unload \(loaded)") { await other.unloadModel() }
        }
        for resident in residents { await resident.releaseGPU() }
        // Admission runs after the unload so it sees the memory actually returned,
        // not what releasing references was supposed to free.
        switch await admit({ $0.admitLoad(model) }) {
        case .rejected(let error):
            throw error
        case .allowed(let warnings) where !warnings.isEmpty:
            update(jobID) { job in job.warnings += warnings.filter { !job.warnings.contains($0) } }
        case .allowed:
            break
        }
        if model.compilesForNeuralEngine {
            update(jobID) { $0.loadingNote = Self.neuralEngineNote }
        }
        defer { update(jobID) { $0.loadingNote = nil } }
        try await StageLog.measure("load \(model.id)") { try await engine.loadModel(id: model.id) }
    }

    /// Memory freed by the previous job or an unload reaches the system with a delay (measured after
    /// a Z-Image 768² job: footprint 16.8 GB right after it finished, 8.1 GB 1 s later, with the
    /// kernel briefly reporting critical pressure). A job started right away would be refused on
    /// that stale snapshot, so a rejection is re-checked until the memory settles.
    private func admit(_ decide: (MemoryBudgetManager) -> AdmissionDecision) async -> AdmissionDecision {
        let start = ContinuousClock.now
        var decision = decide(memory)
        guard case .rejected = decision else { return decision }
        while case .rejected = decision, ContinuousClock.now < start + memorySettleTimeout {
            try? await Task.sleep(for: .milliseconds(250))
            decision = decide(memory)
        }
        StageLog.note(String(format: "memory admission after %.2f s wait: %@",
                             (ContinuousClock.now - start).seconds, decision.isAllowed ? "allowed" : "rejected"))
        return decision
    }

    public static let neuralEngineNote = "Jeśli model był ostatnio nieużywany lub przełączono model SDXL, system kompiluje go dla Neural Engine (zwykle 1–2 min). Kolejne ładowanie trwa ok. 1 s."


    private static func message(for error: any Error) -> String {
        (error as? any LocalizedError)?.errorDescription ?? String(describing: error)
    }

    // MARK: State helpers

    private func update(_ id: UUID, emit shouldEmit: Bool = true, _ change: (inout JobSnapshot) -> Void) {
        guard var job = jobs[id] else { return }
        change(&job)
        jobs[id] = job
        if shouldEmit { emit(.jobUpdated(job)) }
    }

    private func finish(_ id: UUID, _ state: JobState) {
        update(id) {
            $0.state = state
            $0.finishedAt = Date()
            $0.preview = nil
        }
        let pending = waiters.removeValue(forKey: id) ?? []
        pending.forEach { $0.resume(returning: state) }
    }

    private func emit(_ event: CoordinatorEvent) {
        for continuation in subscribers.values { continuation.yield(event) }
    }
}
