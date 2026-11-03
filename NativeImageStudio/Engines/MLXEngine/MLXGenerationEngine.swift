import CoreGraphics
import Domain
import Foundation
import Infrastructure

/// Measurements of the last finished run (for benchmarks).
public struct MLXRunStats: Sendable, Equatable {
    public let requestID: UUID
    public let preprocessSeconds: Double
    public let inferenceSeconds: Double
    public let stepsReported: Int
    /// First step callback → last step callback divided by (steps - 1), i.e. without
    /// text encoding, reference encoding and VAE decode.
    public let secondsPerStep: Double?
    public let peakGPUGB: Double
    public let footprintAfterGB: Double
    public let outcome: String
}

/// MLX backend. One generation at a time; cancellation is cooperative between
/// denoising steps (`EngineCapabilities.cancellation == .perStep`).
public actor MLXGenerationEngine: ImageGenerationEngine, ModelWeightsProvider {
    public nonisolated let id = "mlx"
    public nonisolated let backend = BackendKind.mlx
    public nonisolated let capabilities = EngineCapabilities(
        supportedModes: [.textToImage, .imageToImage, .referenceEdit],
        maxReferenceImages: 4,
        supportedResolutions: [512, 768, 1024],
        dimensionMultiple: Flux2Adapter.dimensionMultiple,
        minDimension: 256,
        maxDimension: 2048,
        maxSteps: 50,
        supportsLoRA: true,
        supportsNegativePrompt: false,
        cancellation: .perStep
    )

    private struct ActiveRun {
        let requestID: UUID
        let flag: CancellationFlag
        let task: Task<Void, Never>
    }

    private let models: ModelRepository
    private let images: ImageRepository
    private let processor = ImageInputProcessor()
    private let gpu = MLXGPUMemory()
    private var adapter: (any MLXPipelineAdapter)?
    private var active: ActiveRun?
    private var livePreview: LivePreviewMode = .off

    public private(set) var lastLoadSeconds: Double?
    public private(set) var lastUnloadReport: UnloadReport?
    public private(set) var lastRunStats: MLXRunStats?

    public init(models: ModelRepository, images: ImageRepository) {
        self.models = models
        self.images = images
        MLXModelStorage.configure()
    }

    public nonisolated var gpuMemory: MLXGPUMemory { MLXGPUMemory() }

    // MARK: ImageGenerationEngine

    public func loadedModelID() -> String? { adapter?.descriptor.id }

    public func capabilities(forModel modelID: String) async -> EngineCapabilities? {
        if let adapter, adapter.descriptor.id == modelID { return adapter.capabilities }
        guard let d = try? await models.descriptor(id: modelID), d.backend == .mlx,
              let a = try? MLXModelLoader.makeAdapter(for: d) else { return nil }
        return a.capabilities
    }

    /// Download weights for `modelID` if missing.
    public func prepareWeights(modelID: String, progress: (@Sendable (Double, String) -> Void)? = nil) async throws {
        let d = try await models.descriptor(id: modelID)
        let a = try MLXModelLoader.makeAdapter(for: d)
        try await a.prepareWeights(progress: progress)
    }

    // MARK: ModelWeightsProvider

    public func isInstalled(modelID: String) async -> Bool {
        guard let d = try? await models.descriptor(id: modelID), d.backend == .mlx,
              let a = try? MLXModelLoader.makeAdapter(for: d) else { return false }
        return a.isInstalled()
    }

    public func install(modelID: String, progress: (@Sendable (Double, String) -> Void)?) async throws {
        try await prepareWeights(modelID: modelID, progress: progress)
    }

    public func installedSizeBytes(modelID: String) async -> Int64 {
        guard let d = try? await models.descriptor(id: modelID), d.backend == .mlx,
              let url = try? MLXModelLoader.makeAdapter(for: d).ownedWeightsURL else { return 0 }
        return diskUsage(of: url)
    }

    public func remove(modelID: String) async throws -> [String] {
        if adapter?.descriptor.id == modelID { await unloadModel() }
        let d = try await models.descriptor(id: modelID)
        let a = try MLXModelLoader.makeAdapter(for: d)
        if let url = a.ownedWeightsURL { try FileManager.default.removeItem(at: url) }
        return a.sharedComponents
    }

    public func loadModel(id modelID: String) async throws {
        if adapter?.descriptor.id == modelID { return }
        await unloadModel()
        let d = try await models.descriptor(id: modelID)
        let a = try MLXModelLoader.makeAdapter(for: d)
        let start = ContinuousClock.now
        do {
            try await a.load()
        } catch {
            await a.release()
            throw error
        }
        lastLoadSeconds = (ContinuousClock.now - start).seconds
        adapter = a
    }

    public func generate(request: GenerationRequest) async throws -> AsyncThrowingStream<GenerationEvent, any Error> {
        // One run at a time: wait for a previous run to reach its end (normally it already has).
        while let previous = active { await previous.task.value }
        guard let adapter, adapter.descriptor.id == request.modelID else { throw GenerationError.modelNotLoaded }

        let flag = CancellationFlag()
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: GenerationEvent.self)
        // Dropping the stream (consumer task cancelled / iteration abandoned) must stop
        // the GPU work too: Swift task cancellation alone does not stop MLX's lazily
        // scheduled graph, so the pipeline polls this flag between steps.
        continuation.onTermination = { termination in
            if case .cancelled = termination { flag.cancel() }
        }
        let processor = self.processor
        let images = self.images
        let gpu = self.gpu
        // Without a VAE preview path, a full-decode request falls back to the approximate preview.
        let preview = livePreview == .fullDecode && !adapter.supportsFullDecodePreview ? .approximate : livePreview
        let task = Task.detached(priority: .userInitiated) {
            let (stats, failure) = await Self.execute(
                request, adapter: adapter, flag: flag, continuation: continuation,
                processor: processor, images: images, gpu: gpu, preview: preview)
            // Mark the engine idle *before* closing the stream, so a consumer that
            // immediately submits the next request never sees a busy engine.
            await self.didFinish(stats)
            continuation.finish(throwing: failure)
        }
        active = ActiveRun(requestID: request.id, flag: flag, task: task)
        return stream
    }

    public func setLivePreview(_ mode: LivePreviewMode) {
        livePreview = mode
    }

    public func cancel(requestID: UUID) {
        guard let active, active.requestID == requestID else { return }
        active.flag.cancel()
    }

    /// Model-switch procedure: stop the active generation (wait for its safe point),
    /// release pipeline references, synchronize the GPU, clear MLX caches, measure.
    public func unloadModel() async {
        if let active {
            active.flag.cancel()
            await active.task.value
        }
        guard let adapter else { return }
        lastUnloadReport = await MLXModelLoader.release(adapter, gpu: gpu)
        self.adapter = nil
    }

    // MARK: Execution

    private func didFinish(_ stats: MLXRunStats) {
        lastRunStats = stats
        if active?.requestID == stats.requestID { active = nil }
    }

    private static func execute(
        _ request: GenerationRequest,
        adapter: any MLXPipelineAdapter,
        flag: CancellationFlag,
        continuation: AsyncThrowingStream<GenerationEvent, any Error>.Continuation,
        processor: ImageInputProcessor,
        images: ImageRepository,
        gpu: MLXGPUMemory,
        preview: LivePreviewMode
    ) async -> (MLXRunStats, (any Error)?) {
        let clock = ContinuousClock()
        let start = clock.now
        var preprocessSeconds = 0.0
        let stepTimes = StepTimes()
        var outcome = "completed"
        var failure: (any Error)?
        do {
            continuation.yield(.preparing)
            try check(flag)

            continuation.yield(.preprocessingInputs)
            let inputs = try prepareInputs(for: request, processor: processor)
            preprocessSeconds = (clock.now - start).seconds
            try check(flag)

            gpu.resetPeak()
            let callbacks = PipelineCallbacks(
                onStep: { current, total in
                    stepTimes.record(current, at: clock.now)
                    continuation.yield(.step(current: current, total: total))
                    if current == total { continuation.yield(.decoding) }
                },
                isCancelled: { flag.isCancelled },
                livePreview: preview,
                previewFactors: preview == .approximate ? LatentRGBFactors.bundled(family: adapter.descriptor.architecture) : nil,
                onPreview: { continuation.yield(.preview($0)) }
            )
            let image = try await adapter.run(request, inputs: inputs, callbacks: callbacks)
            let elapsed = (clock.now - start).seconds

            let metadata = GenerationMetadata(
                request: request, backend: BackendKind.mlx.rawValue,
                inputs: InputProvenance.records(for: request))
            let url = try await images.save(image, metadata: metadata, inputs: request.allImageFiles)
            let runStats = RunStats(
                secondsPerStep: stepTimes.secondsPerStep, peakMemoryGB: gpu.peakBytes.gigabytes,
                peakMemorySource: "mlx-active-peak",
                thermalState: ThermalLevel(ProcessInfo.processInfo.thermalState).rawValue)
            continuation.yield(.completed(GeneratedImage(
                fileURL: url, seed: request.seed, elapsedSeconds: elapsed, metadata: metadata, stats: runStats)))
        } catch let error as GenerationError {
            outcome = error == .cancelled ? "cancelled" : "failed"
            failure = error
        } catch is CancellationError {
            outcome = "cancelled"
            failure = GenerationError.cancelled
        } catch {
            outcome = "failed"
            let message = (error as? any LocalizedError)?.errorDescription ?? String(describing: error)
            failure = GenerationError.backendFailure(message)
        }
        // Whatever happened, make sure no GPU work of this run is still in flight.
        gpu.synchronize()
        let stats = MLXRunStats(
            requestID: request.id,
            preprocessSeconds: preprocessSeconds,
            inferenceSeconds: (clock.now - start).seconds - preprocessSeconds,
            stepsReported: stepTimes.count,
            secondsPerStep: stepTimes.secondsPerStep,
            peakGPUGB: gpu.peakBytes.gigabytes,
            footprintAfterGB: DarwinMemoryProbe.processFootprint().gigabytes,
            outcome: outcome
        )
        return (stats, failure)
    }

    private static func check(_ flag: CancellationFlag) throws {
        if flag.isCancelled || Task.isCancelled { throw GenerationError.cancelled }
    }

    /// Decode, orient, convert to sRGB and size inputs for the request (CPU only).
    static func prepareInputs(for request: GenerationRequest, processor: ImageInputProcessor) throws -> PreparedInputs {
        let target = PixelSize(width: request.width, height: request.height)
        do {
            switch request.mode {
            case .textToImage:
                return PreparedInputs(images: [])
            case .imageToImage:
                guard let primary = request.primaryImage else { return PreparedInputs(images: []) }
                return PreparedInputs(images: [try processor.prepare(primary.sourceURL, target: target, mode: request.resizeMode)])
            case .referenceEdit:
                // The first image follows the output geometry; further references keep
                // their own aspect ratio at a similar pixel budget.
                let edge = Int(Double(request.width * request.height).squareRoot())
                let prepared = try request.inputImages.enumerated().map { index, input in
                    if index == 0 {
                        return try processor.prepare(input.sourceURL, target: target, mode: request.resizeMode)
                    }
                    let size = try processor.orientedSize(of: input.sourceURL)
                    let refTarget = ImageInputProcessor.targetSize(
                        aspectRatio: size.aspectRatio, targetEdge: edge, multiple: Flux2Adapter.dimensionMultiple)
                    return try processor.prepare(input.sourceURL, target: refTarget, mode: .fit)
                }
                return PreparedInputs(images: prepared)
            case .inpainting(let mask):
                guard let primary = request.primaryImage else { return PreparedInputs(images: []) }
                return PreparedInputs(
                    images: [try processor.prepare(primary.sourceURL, target: target, mode: request.resizeMode)],
                    mask: try processor.prepare(mask.sourceURL, target: target, mode: request.resizeMode))
            }
        } catch let error as ImageInputError {
            throw GenerationError.inputProcessingFailed(error.localizedDescription)
        }
    }
}
