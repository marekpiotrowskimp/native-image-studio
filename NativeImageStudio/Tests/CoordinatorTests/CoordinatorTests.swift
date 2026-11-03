import Application
import Domain
import Foundation
import Infrastructure
import TestSupport
import Testing

/// Test rig: coordinator + mock engine(s) + model repository + generous memory.
struct Rig {
    let coordinator: GenerationCoordinator
    let batches: BatchCoordinator
    let engine: MockEngine
    let models: ModelRepository
    let dir: URL

    init(
        stepDelay: Duration = .milliseconds(5),
        probe: any SystemMemoryProbe = StaticMemoryProbe.gb(),
        memorySettleTimeout: Duration = .milliseconds(300),
        descriptors: [ModelDescriptor] = [TestModels.descriptor(), TestModels.descriptor(id: "other-model")],
        extraEngines: [any ImageGenerationEngine] = []
    ) throws {
        dir = try FixtureFactory.temporaryDirectory()
        engine = MockEngine(stepDelay: stepDelay, outputDirectory: dir)
        models = ModelRepository(builtIn: descriptors)
        coordinator = GenerationCoordinator(
            registry: EngineRegistry([engine] + extraEngines),
            models: models,
            memory: MemoryBudgetManager(probe: probe),
            maxUpdatesPerSecond: 1000,
            memorySettleTimeout: memorySettleTimeout)
        batches = BatchCoordinator(coordinator: coordinator)
    }

    func image(_ name: String) throws -> URL {
        try FixtureFactory.write(FixtureFactory.quadrantImage(width: 64, height: 64),
                                 to: dir.appendingPathComponent("\(name).png"), type: .png)
    }
}

/// Collects state labels per job from the coordinator event stream.
actor StateRecorder {
    private(set) var labels: [UUID: [String]] = [:]

    func record(_ event: CoordinatorEvent) {
        guard case .jobUpdated(let job) = event else { return }
        var list = labels[job.id, default: []]
        if list.last != job.state.label { list.append(job.state.label) }
        labels[job.id] = list
    }

    func start(_ stream: AsyncStream<CoordinatorEvent>) -> Task<Void, Never> {
        Task { for await e in stream { self.record(e) } }
    }
}

actor FakeResident: GPUResident {
    private(set) var releases = 0
    func releaseGPU() { releases += 1 }
}

/// Loading notes per job (only events that carry one).
actor NoteRecorder {
    private var byJob: [UUID: [(state: String, note: String)]] = [:]

    func notes(_ id: UUID) -> [(state: String, note: String)] { byJob[id] ?? [] }

    func start(_ stream: AsyncStream<CoordinatorEvent>) -> Task<Void, Never> {
        Task {
            for await e in stream {
                guard case .jobUpdated(let job) = e, let note = job.loadingNote else { continue }
                self.append(job.id, (job.state.label, note))
            }
        }
    }

    private func append(_ id: UUID, _ entry: (state: String, note: String)) { byJob[id, default: []].append(entry) }
}

@Suite("Generation coordinator")
struct CoordinatorTests {
    @Test func lifecycleQueuedLoadingRunningCompleted() async throws {
        let rig = try Rig()
        let recorder = StateRecorder()
        let listener = await recorder.start(await rig.coordinator.events())
        let id = try await rig.coordinator.submit(TestModels.request())
        let state = await rig.coordinator.waitForCompletion(id)
        guard case .completed(let image) = state else { Issue.record("expected completed, got \(state)"); return }
        #expect(image.metadata.requestID == id)
        try await Task.sleep(for: .milliseconds(50))
        listener.cancel()
        let labels = await recorder.labels[id] ?? []
        #expect(labels == ["Queued", "Loading", "Running", "Completed"])
    }

    @Test func invalidRequestIsRejectedAtSubmit() async throws {
        let rig = try Rig()
        await #expect(throws: RequestValidationError.self) {
            try await rig.coordinator.submit(TestModels.request(width: 500))
        }
        await #expect(throws: ModelStorageError.self) {
            try await rig.coordinator.submit(TestModels.request(model: "missing"))
        }
        #expect(await rig.coordinator.allJobs().isEmpty)
    }

    @Test func onlyOneGenerationAtATimeInFIFOOrder() async throws {
        let rig = try Rig()
        var ids: [UUID] = []
        for i in 0..<4 { ids.append(try await rig.coordinator.submit(TestModels.request(prompt: "job \(i)"))) }
        await rig.coordinator.waitUntilIdle()
        #expect(await rig.engine.maxConcurrentRuns == 1)
        #expect(await rig.engine.generatedRequestIDs == ids)
        #expect(await rig.engine.loadCount == 1)  // same model, no reloads
    }

    @Test func priorityChangeAffectsOrder() async throws {
        let rig = try Rig(stepDelay: .milliseconds(20))
        let first = try await rig.coordinator.submit(TestModels.request(prompt: "first"))
        let a = try await rig.coordinator.submit(TestModels.request(prompt: "a"))
        let b = try await rig.coordinator.submit(TestModels.request(prompt: "b"))
        let urgent = try await rig.coordinator.submit(TestModels.request(prompt: "urgent"), priority: .high)
        await rig.coordinator.setPriority(b, .high)
        await rig.coordinator.waitUntilIdle()
        let order = await rig.engine.generatedRequestIDs
        #expect(order.first == first)
        // b keeps its original FIFO slot inside the high level, so it precedes `urgent`.
        #expect(Array(order.dropFirst()) == [b, urgent, a])
    }

    @Test func cancelQueuedJobImmediately() async throws {
        let rig = try Rig(stepDelay: .milliseconds(20))
        let running = try await rig.coordinator.submit(TestModels.request(prompt: "running"))
        let queued = try await rig.coordinator.submit(TestModels.request(prompt: "queued"))
        await rig.coordinator.cancel(queued)
        #expect(await rig.coordinator.snapshot(queued)?.state == .cancelled)
        #expect(await rig.coordinator.waitForCompletion(running).isTerminal)
        #expect(await !rig.engine.generatedRequestIDs.contains(queued))
    }

    @Test func cancelRunningJobWaitsForEngineSafePoint() async throws {
        let rig = try Rig(stepDelay: .milliseconds(30))
        let id = try await rig.coordinator.submit(TestModels.request(steps: 20))
        // Wait until it is running.
        while true {
            if case .running(let step, _) = await rig.coordinator.snapshot(id)?.state, step >= 2 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        await rig.coordinator.cancel(id)
        // Not yet cancelled: the engine has not reached its next step boundary.
        let immediately = await rig.coordinator.snapshot(id)?.state
        #expect(immediately != .cancelled)
        let final = await rig.coordinator.waitForCompletion(id)
        #expect(final == .cancelled)
        let stoppedAt = await rig.engine.cancelledAtStep[id]
        #expect(stoppedAt != nil && stoppedAt! < 20)
    }

    @Test func coordinatorKeepsWorkingAfterCancel() async throws {
        let rig = try Rig(stepDelay: .milliseconds(10))
        let a = try await rig.coordinator.submit(TestModels.request(steps: 30))
        try await Task.sleep(for: .milliseconds(60))
        await rig.coordinator.cancel(a)
        let b = try await rig.coordinator.submit(TestModels.request(prompt: "next"))
        #expect(await rig.coordinator.waitForCompletion(a) == .cancelled)
        if case .completed = await rig.coordinator.waitForCompletion(b) {} else { Issue.record("b should complete") }
    }

    @Test func engineFailureMarksFailedAndQueueContinues() async throws {
        let rig = try Rig()
        await rig.engine.setBehavior(.fail("GPU exploded"), forPromptContaining: "boom")
        let bad = try await rig.coordinator.submit(TestModels.request(prompt: "boom"))
        let good = try await rig.coordinator.submit(TestModels.request(prompt: "fine"))
        #expect(await rig.coordinator.waitForCompletion(bad) == .failed("Błąd silnika: GPU exploded"))
        if case .completed = await rig.coordinator.waitForCompletion(good) {} else { Issue.record("good should complete") }
    }

    @Test func modelSwitchUnloadsBeforeLoading() async throws {
        let rig = try Rig()
        let a = try await rig.coordinator.submit(TestModels.request(model: "test-model"))
        let b = try await rig.coordinator.submit(TestModels.request(model: "other-model"))
        _ = await rig.coordinator.waitForCompletion(a)
        _ = await rig.coordinator.waitForCompletion(b)
        #expect(await rig.engine.loadCount == 2)
        #expect(await rig.engine.unloadCount == 1)
        #expect(await rig.engine.loadedModel == "other-model")
    }

    @Test func switchingBackendUnloadsOtherEngine() async throws {
        let dir = try FixtureFactory.temporaryDirectory()
        let coreML = MockEngine(id: "coreml-mock", backend: .coreml, outputDirectory: dir)
        let rig = try Rig(
            descriptors: [TestModels.descriptor(), TestModels.descriptor(id: "sdxl", backend: .coreml)],
            extraEngines: [coreML])
        let a = try await rig.coordinator.submit(TestModels.request(model: "test-model"))
        let b = try await rig.coordinator.submit(TestModels.request(model: "sdxl"))
        _ = await rig.coordinator.waitForCompletion(a)
        _ = await rig.coordinator.waitForCompletion(b)
        #expect(await rig.engine.loadedModel == nil)
        #expect(await rig.engine.unloadCount == 1)
        #expect(await coreML.loadedModel == "sdxl")
    }

    @Test func neuralEngineLoadCarriesNoteOnlyWhileLoading() async throws {
        let dir = try FixtureFactory.temporaryDirectory()
        let coreML = MockEngine(id: "coreml-mock", backend: .coreml, outputDirectory: dir)
        let rig = try Rig(
            descriptors: [TestModels.descriptor(), TestModels.descriptor(id: "sdxl", backend: .coreml)],
            extraEngines: [coreML])
        let notes = NoteRecorder()
        let listener = await notes.start(await rig.coordinator.events())
        let mlx = try await rig.coordinator.submit(TestModels.request(model: "test-model"))
        let ane = try await rig.coordinator.submit(TestModels.request(model: "sdxl"))
        _ = await rig.coordinator.waitForCompletion(mlx)
        _ = await rig.coordinator.waitForCompletion(ane)
        try await Task.sleep(for: .milliseconds(50))
        listener.cancel()

        #expect(await notes.notes(mlx).isEmpty)
        let aneNotes = await notes.notes(ane)
        #expect(aneNotes.contains { $0 == ("Loading", GenerationCoordinator.neuralEngineNote) })
        #expect(aneNotes.allSatisfy { $0.state == "Loading" })
        #expect(await rig.coordinator.snapshot(ane)?.loadingNote == nil)
    }

    @Test func exclusiveGPUWaitsForJobsUnloadsModelsAndHoldsNewJobs() async throws {
        let rig = try Rig(stepDelay: .milliseconds(10))
        let running = try await rig.coordinator.submit(TestModels.request())
        let coordinator = rig.coordinator
        let engine = rig.engine
        let held = try await coordinator.withExclusiveGPU { () async throws -> UUID in
            // The earlier job finished before the GPU was handed over, and its model is gone.
            #expect(await coordinator.snapshot(running)?.state.isTerminal == true)
            #expect(await engine.loadedModel == nil)
            let late = try await coordinator.submit(TestModels.request())
            try await Task.sleep(for: .milliseconds(100))
            #expect(await coordinator.snapshot(late)?.state == .queued)
            return late
        }
        let state = await rig.coordinator.waitForCompletion(held)
        #expect(state.isTerminal && state.label == "Completed")
    }

    @Test func residentIsReleasedBeforeAnImageModelLoads() async throws {
        let rig = try Rig()
        let resident = FakeResident()
        await rig.coordinator.register(resident: resident)
        let id = try await rig.coordinator.submit(TestModels.request())
        _ = await rig.coordinator.waitForCompletion(id)
        #expect(await resident.releases == 1)
        // Same model again: nothing to load, nothing to release.
        let again = try await rig.coordinator.submit(TestModels.request())
        _ = await rig.coordinator.waitForCompletion(again)
        #expect(await resident.releases == 1)
    }

    @Test func memoryRejectionFailsJobWithReadableMessage() async throws {
        let profile = ModelDescriptor.MemoryProfile(residentGB: 6, activationGBPerMegapixel: 2, perReferenceImageGB: 1)
        let rig = try Rig(
            probe: StaticMemoryProbe.gb(physical: 24, footprint: 1, available: 7),
            descriptors: [TestModels.descriptor(memory: profile)])
        let id = try await rig.coordinator.submit(TestModels.request(width: 2048, height: 2048))
        let state = await rig.coordinator.waitForCompletion(id)
        guard case .failed(let message) = state else { Issue.record("expected failure, got \(state)"); return }
        #expect(message.contains("Za mało pamięci"))
    }

    @Test func previewFramesReachTheSnapshotAndAreDroppedAtTheEnd() async throws {
        let rig = try Rig(stepDelay: .milliseconds(20))
        await rig.engine.setLivePreview(.approximate)
        let events = await rig.coordinator.events()
        let seen = PreviewRecorder()
        let listener = Task { for await e in events { if case .jobUpdated(let job) = e { await seen.record(job) } } }
        let id = try await rig.coordinator.submit(TestModels.request(steps: 3))
        _ = await rig.coordinator.waitForCompletion(id)
        try? await Task.sleep(for: .milliseconds(50))
        listener.cancel()
        #expect(await seen.steps == [1, 2, 3])
        #expect(await rig.coordinator.snapshot(id)?.preview == nil)
    }

    @Test func jobWaitsForMemoryFreedByThePreviousJobToSettle() async throws {
        // Right after a job the footprint still holds its freed buffers and the kernel may report
        // critical pressure; a moment later the memory is back (measured with Z-Image, see admit()).
        let profile = ModelDescriptor.MemoryProfile(residentGB: 6, activationGBPerMegapixel: 2, perReferenceImageGB: 0)
        let probe = SequenceMemoryProbe([
            .gb(footprint: 16.8, available: 3.6, pressure: .critical),
            .gb(footprint: 16.8, available: 3.6),
            .gb(footprint: 8.1, available: 12.7),
        ])
        let rig = try Rig(probe: probe, memorySettleTimeout: .seconds(5),
                          descriptors: [TestModels.descriptor(memory: profile)])
        let id = try await rig.coordinator.submit(TestModels.request(width: 1024, height: 1024))
        let state = await rig.coordinator.waitForCompletion(id)
        guard case .completed = state else { Issue.record("expected completion, got \(state)"); return }
        #expect(probe.callCount >= 3)
    }
}

@Suite("Batch coordinator")
struct BatchCoordinatorTests {
    @Test func batchRunsEachPhotoAsJobWithSharedID() async throws {
        let rig = try Rig()
        let photos = try (0..<3).map { try rig.image("p\($0)") }
        let template = TestModels.request(mode: .imageToImage(strength: 0.5), inputs: [], prompt: "cinematic")
        let batch = await rig.batches.submitBatch(template: template, inputs: photos)
        let progress = await rig.batches.waitForBatch(batch)
        #expect(progress.total == 3 && progress.completed == 3 && progress.isFinished)
        #expect(progress.fractionComplete == 1)
        let jobs = await rig.coordinator.jobs(inBatch: batch)
        #expect(jobs.count == 3)
        #expect(Set(jobs.compactMap { $0.request.inputImages.first?.sourceURL }) == Set(photos))
        #expect(jobs.allSatisfy { $0.request.prompt == "cinematic" && $0.request.batchID == batch })
        #expect(await rig.engine.loadCount == 1)  // no reload between photos
    }

    @Test func failureOfOnePhotoDoesNotStopOthers() async throws {
        let rig = try Rig()
        await rig.engine.setBehavior(.fail("bad photo"), forPromptContaining: "x")
        let good = try (0..<2).map { try rig.image("g\($0)") }
        let unreadable = rig.dir.appendingPathComponent("broken.png")
        try Data("nope".utf8).write(to: unreadable)
        let template = TestModels.request(mode: .imageToImage(strength: 0.5), prompt: "style")
        let batch = await rig.batches.submitBatch(template: template, inputs: [good[0], unreadable, good[1]])
        let progress = await rig.batches.waitForBatch(batch)
        #expect(progress.total == 3)
        #expect(progress.completed == 2)
        #expect(progress.failed == 1)
        #expect(await rig.batches.failures(batch).first?.fileURL == unreadable)
    }

    @Test func cancellingBatchCancelsAllItsJobsOnly() async throws {
        let rig = try Rig(stepDelay: .milliseconds(20))
        let other = try await rig.coordinator.submit(TestModels.request(prompt: "unrelated", steps: 2))
        let photos = try (0..<4).map { try rig.image("c\($0)") }
        let template = TestModels.request(mode: .imageToImage(strength: 0.5), prompt: "warm light", steps: 10)
        let batch = await rig.batches.submitBatch(template: template, inputs: photos)
        // Let the first batch job start.
        try await Task.sleep(for: .milliseconds(120))
        await rig.batches.cancelBatch(batch)
        let progress = await rig.batches.waitForBatch(batch)
        #expect(progress.isFinished)
        #expect(progress.cancelled + progress.completed == 4)
        #expect(progress.cancelled >= 3)
        if case .completed = await rig.coordinator.waitForCompletion(other) {} else { Issue.record("unrelated job must complete") }
    }

    @Test func sizingFollowsEachPhoto() async throws {
        let rig = try Rig()
        let photos = try (0..<2).map { try rig.image("s\($0)") }
        let template = TestModels.request(mode: .imageToImage(strength: 0.5), prompt: "x2")
        let batch = await rig.batches.submitBatch(template: template, inputs: photos) { url in
            url.lastPathComponent == "s1.png" ? (width: 768, height: 512) : nil
        }
        _ = await rig.batches.waitForBatch(batch)
        let sizes = await rig.coordinator.jobs(inBatch: batch).map { "\($0.request.width)x\($0.request.height)" }.sorted()
        #expect(sizes == ["512x512", "768x512"])
    }
}

@Suite("Memory budget")
struct MemoryBudgetTests {
    let profile = ModelDescriptor.MemoryProfile(residentGB: 8, activationGBPerMegapixel: 2, perReferenceImageGB: 1)

    @Test func estimateScalesWithResolutionAndReferences() {
        let m = MemoryBudgetManager(probe: StaticMemoryProbe.gb())
        let model = TestModels.descriptor(memory: profile)
        let base = m.estimate(model: model, width: 1024, height: 1024, referenceImages: 0, includeLoad: false)
        let refs = m.estimate(model: model, width: 1024, height: 1024, referenceImages: 3, includeLoad: false)
        let big = m.estimate(model: model, width: 2048, height: 2048, referenceImages: 0, includeLoad: true)
        #expect(refs.totalGB > base.totalGB)
        #expect(abs(refs.referencesGB - 3 * 1.048576) < 0.001)
        #expect(big.loadGB == 8)
        #expect(big.activationGB > base.activationGB * 3.9)
    }

    @Test func rejectsWhenReferenceImagesDoNotFit() {
        let m = MemoryBudgetManager(probe: StaticMemoryProbe.gb(available: 5))
        let model = TestModels.descriptor(memory: profile)
        let ok = TestModels.request(mode: .referenceEdit, inputs: [InputImage(sourceURL: URL(fileURLWithPath: "/a"), role: .primary)])
        #expect(m.admitJob(ok, model: model, modelLoaded: true).isAllowed)
        let many = TestModels.request(mode: .referenceEdit, inputs: (0..<3).map { InputImage(sourceURL: URL(fileURLWithPath: "/\($0)"), role: .reference) },
                                      width: 1024, height: 1024)
        guard case .rejected(let error) = m.admitJob(many, model: model, modelLoaded: true) else {
            Issue.record("expected rejection"); return
        }
        #expect(error.errorDescription?.contains("Obrazy wejściowe (3)") == true)
    }

    @Test func gpuCacheCountsAsReclaimable() {
        let model = TestModels.descriptor(memory: profile)
        let tight = MemoryBudgetManager(probe: StaticMemoryProbe.gb(available: 3, gpuCache: 0))
        let withCache = MemoryBudgetManager(probe: StaticMemoryProbe.gb(available: 3, gpuCache: 2))
        let r = TestModels.request(width: 1024, height: 1024)
        #expect(!tight.admitJob(r, model: model, modelLoaded: true).isAllowed)
        #expect(withCache.admitJob(r, model: model, modelLoaded: true).isAllowed)
    }

    @Test func processCeilingLimitsEvenWithFreeSystemMemory() {
        // 24 GB × 0.8 = 19.2 GB ceiling, footprint already 18 GB.
        let m = MemoryBudgetManager(probe: StaticMemoryProbe.gb(physical: 24, footprint: 18, available: 20))
        #expect(m.availableGB(StaticMemoryProbe.gb(physical: 24, footprint: 18, available: 20).value) < 1.3)
        #expect(!m.admitLoad(TestModels.descriptor(memory: profile)).isAllowed)
    }

    @Test func thermalAndPressureGates() {
        let model = TestModels.descriptor(memory: profile)
        let hot = MemoryBudgetManager(probe: StaticMemoryProbe.gb(thermal: .critical))
        guard case .rejected(.thermalThrottling) = hot.admitJob(TestModels.request(), model: model, modelLoaded: true) else {
            Issue.record("critical thermal must reject"); return
        }
        let warm = MemoryBudgetManager(probe: StaticMemoryProbe.gb(thermal: .serious))
        guard case .allowed(let warnings) = warm.admitJob(TestModels.request(), model: model, modelLoaded: true) else {
            Issue.record("serious thermal should warn only"); return
        }
        #expect(!warnings.isEmpty)
        let pressured = MemoryBudgetManager(probe: StaticMemoryProbe.gb(pressure: .critical))
        #expect(!pressured.admitLoad(model).isAllowed)
    }

    @Test func minimumMemoryThreshold() {
        let m = MemoryBudgetManager(probe: StaticMemoryProbe.gb(physical: 16))
        #expect(!m.admitLoad(TestModels.descriptor(minimumMemoryGB: 24)).isAllowed)
        guard case .allowed(let w) = m.admitLoad(TestModels.descriptor(minimumMemoryGB: 8)) else {
            Issue.record("should allow"); return
        }
        #expect(w.contains { $0.contains("Brak zmierzonego profilu") })
    }

    @Test func darwinProbeReturnsPlausibleValues() {
        let s = DarwinMemoryProbe().snapshot()
        #expect(s.physicalBytes > 0)
        #expect(s.processFootprintBytes > 0)
        #expect(s.systemAvailableBytes > 0)
        #expect(s.systemAvailableBytes < s.physicalBytes)
    }
}

/// Preview steps seen in job updates (deduplicated, in order).
actor PreviewRecorder {
    private(set) var steps: [Int] = []
    func record(_ job: JobSnapshot) {
        if let step = job.preview?.step, steps.last != step { steps.append(step) }
    }
}
