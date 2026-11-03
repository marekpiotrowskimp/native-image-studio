import CoreGraphics
import Domain
import Foundation
import Infrastructure

/// Measurements of the last finished Core ML run.
public struct CoreMLRunStats: Sendable, Equatable {
    public let requestID: UUID
    public let inferenceSeconds: Double
    public let stepsReported: Int
    public let secondsPerStep: Double?
    public let footprintAfterGB: Double
    public let outcome: String
}

/// Core ML backend (SDXL via apple/ml-stable-diffusion). Text-to-image and
/// image-to-image; the step callback doubles as the cancellation safe point.
public actor CoreMLGenerationEngine: ImageGenerationEngine, ModelWeightsProvider {
    public nonisolated let id = "coreml"
    public nonisolated let backend = BackendKind.coreml
    public nonisolated let capabilities = EngineCapabilities(
        supportedModes: [.textToImage, .imageToImage],
        maxReferenceImages: 0,
        supportedResolutions: [SDXLPipelineAdapter.fixedResolution],
        dimensionMultiple: 8,
        minDimension: SDXLPipelineAdapter.fixedResolution,
        maxDimension: SDXLPipelineAdapter.fixedResolution,
        minSteps: 2,
        maxSteps: 50,
        supportsLoRA: false,
        supportsNegativePrompt: true,
        cancellation: .perStep)

    private struct ActiveRun {
        let requestID: UUID
        let flag: CancellationFlag
        let task: Task<Void, Never>
    }

    private let models: ModelRepository
    private let images: ImageRepository
    private let processor = ImageInputProcessor()
    private var adapter: SDXLPipelineAdapter?
    private var active: ActiveRun?
    private var livePreview: LivePreviewMode = .off

    public private(set) var lastLoadSeconds: Double?
    public private(set) var lastRunStats: CoreMLRunStats?
    public private(set) var lastUnloadFootprint: (before: Double, after: Double)?

    public init(models: ModelRepository, images: ImageRepository) {
        self.models = models
        self.images = images
    }

    public func loadedModelID() -> String? { adapter?.descriptor.id }

    public func capabilities(forModel modelID: String) async -> EngineCapabilities? {
        guard let d = try? await models.descriptor(id: modelID), d.backend == .coreml else { return nil }
        // Before download the encoder's presence is unknown; trust the manifest.
        let hasEncoder = !CoreMLModelLoader.isInstalled(d) || CoreMLModelLoader.hasEncoder(d)
        return SDXLPipelineAdapter.capabilities(for: d, hasEncoder: hasEncoder)
    }

    // MARK: ModelWeightsProvider

    public func isInstalled(modelID: String) async -> Bool {
        guard let d = try? await models.descriptor(id: modelID) else { return false }
        return CoreMLModelLoader.isInstalled(d)
    }

    public func install(modelID: String, progress: (@Sendable (Double, String) -> Void)?) async throws {
        let d = try await models.descriptor(id: modelID)
        try await CoreMLModelLoader.download(d, progress: progress)
    }

    public func installedSizeBytes(modelID: String) async -> Int64 {
        guard let d = try? await models.descriptor(id: modelID), CoreMLModelLoader.isInstalled(d) else { return 0 }
        return diskUsage(of: CoreMLModelLoader.resourceDirectory(for: d))
    }

    public func remove(modelID: String) async throws -> [String] {
        if adapter?.descriptor.id == modelID { await unloadModel() }
        let d = try await models.descriptor(id: modelID)
        // Only app-managed directories are deleted; a user-provided `resourcePath` is left alone.
        guard d.backendOptions["resourcePath"] == nil else {
            throw GenerationError.backendFailure("Zasoby w \(CoreMLModelLoader.resourceDirectory(for: d).path) są zarządzane ręcznie — usuń je w Finderze.")
        }
        let dir = CoreMLModelLoader.resourceDirectory(for: d)
        if FileManager.default.fileExists(atPath: dir.path) { try FileManager.default.removeItem(at: dir) }
        return []
    }

    // MARK: Lifecycle

    public func loadModel(id modelID: String) async throws {
        if adapter?.descriptor.id == modelID { return }
        await unloadModel()
        let d = try await models.descriptor(id: modelID)
        guard d.backend == .coreml, d.architecture == "sdxl" else {
            throw GenerationError.backendFailure("Brak adaptera Core ML dla \(d.architecture).")
        }
        guard CoreMLModelLoader.isInstalled(d) else {
            throw GenerationError.modelNotFound("\(d.name): brak zasobów Core ML w \(CoreMLModelLoader.resourceDirectory(for: d).path).")
        }
        let a = SDXLPipelineAdapter(descriptor: d)
        let start = ContinuousClock.now
        // Core ML loading (and first-time ANE compilation) blocks; keep it off the actor's executor.
        try await Task.detached(priority: .userInitiated) { try a.load() }.value
        lastLoadSeconds = (ContinuousClock.now - start).seconds
        adapter = a
    }

    public func unloadModel() async {
        if let active {
            active.flag.cancel()
            await active.task.value
        }
        guard let adapter else { return }
        let before = DarwinMemoryProbe.processFootprint().gigabytes
        adapter.release()
        self.adapter = nil
        lastUnloadFootprint = (before, DarwinMemoryProbe.processFootprint().gigabytes)
    }

    public func setLivePreview(_ mode: LivePreviewMode) {
        livePreview = mode
    }

    public func cancel(requestID: UUID) {
        guard let active, active.requestID == requestID else { return }
        active.flag.cancel()
    }

    public func generate(request: GenerationRequest) async throws -> AsyncThrowingStream<GenerationEvent, any Error> {
        // One run at a time: wait for a previous run to reach its end (normally it already has).
        while let previous = active { await previous.task.value }
        guard let adapter, adapter.descriptor.id == request.modelID else { throw GenerationError.modelNotLoaded }
        let flag = CancellationFlag()
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: GenerationEvent.self)
        continuation.onTermination = { termination in
            if case .cancelled = termination { flag.cancel() }
        }
        let processor = self.processor
        let images = self.images
        let preview = livePreview
        let task = Task.detached(priority: .userInitiated) {
            let (stats, failure) = await Self.execute(request, adapter: adapter, flag: flag, continuation: continuation,
                                                      processor: processor, images: images, preview: preview)
            await self.didFinish(stats)
            continuation.finish(throwing: failure)
        }
        active = ActiveRun(requestID: request.id, flag: flag, task: task)
        return stream
    }

    private func didFinish(_ stats: CoreMLRunStats) {
        lastRunStats = stats
        if active?.requestID == stats.requestID { active = nil }
    }

    private static func execute(
        _ request: GenerationRequest,
        adapter: SDXLPipelineAdapter,
        flag: CancellationFlag,
        continuation: AsyncThrowingStream<GenerationEvent, any Error>.Continuation,
        processor: ImageInputProcessor,
        images: ImageRepository,
        preview mode: LivePreviewMode
    ) async -> (CoreMLRunStats, (any Error)?) {
        let start = ContinuousClock.now
        let stepTimes = StepTimes()
        var outcome = "completed"
        var failure: (any Error)?
        do {
            continuation.yield(.preparing)
            var startingImage: CGImage?
            if case .imageToImage = request.mode, let primary = request.primaryImage {
                continuation.yield(.preprocessingInputs)
                do {
                    startingImage = try processor.prepare(
                        primary.sourceURL, target: PixelSize(width: request.width, height: request.height),
                        mode: request.resizeMode)
                } catch {
                    throw GenerationError.inputProcessingFailed(error.localizedDescription)
                }
            }
            if flag.isCancelled { throw GenerationError.cancelled }
            let preview = CoreMLPreviewSink(
                mode: mode,
                factors: mode == .approximate ? LatentRGBFactors.bundled(family: adapter.descriptor.architecture) : nil,
                onPreview: { continuation.yield(.preview($0)) })
            let image = try adapter.run(request, startingImage: startingImage, flag: flag, preview: preview) { current, total in
                stepTimes.record(current)
                continuation.yield(.step(current: current, total: total))
                if current == total { continuation.yield(.decoding) }
            }
            let elapsed = (ContinuousClock.now - start).seconds
            let metadata = GenerationMetadata(request: request, backend: BackendKind.coreml.rawValue,
                                              inputs: InputProvenance.records(for: request))
            let url = try await images.save(image, metadata: metadata, inputs: request.allImageFiles)
            let runStats = RunStats(
                secondsPerStep: stepTimes.secondsPerStep,
                peakMemoryGB: DarwinMemoryProbe.processPeakFootprint().gigabytes,
                peakMemorySource: "process-peak-footprint",
                thermalState: ThermalLevel(ProcessInfo.processInfo.thermalState).rawValue)
            continuation.yield(.completed(GeneratedImage(
                fileURL: url, seed: request.seed, elapsedSeconds: elapsed, metadata: metadata, stats: runStats)))
        } catch let error as GenerationError {
            outcome = error == .cancelled ? "cancelled" : "failed"
            failure = error
        } catch {
            outcome = "failed"
            failure = GenerationError.backendFailure(error.localizedDescription)
        }
        let stats = CoreMLRunStats(
            requestID: request.id,
            inferenceSeconds: (ContinuousClock.now - start).seconds,
            stepsReported: stepTimes.count,
            secondsPerStep: stepTimes.secondsPerStep,
            footprintAfterGB: DarwinMemoryProbe.processFootprint().gigabytes,
            outcome: outcome)
        return (stats, failure)
    }
}
