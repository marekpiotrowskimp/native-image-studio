import CoreGraphics
import Domain
import Foundation
import Infrastructure

/// Scriptable engine for coordinator tests. Honors cancellation between "steps".
public actor MockEngine: ImageGenerationEngine {
    public enum Behavior: Sendable {
        case succeed
        case fail(String)
    }

    public nonisolated let id: String
    public nonisolated let backend: BackendKind
    public nonisolated let capabilities: EngineCapabilities

    public private(set) var loadedModel: String?
    public private(set) var loadCount = 0
    public private(set) var unloadCount = 0
    public private(set) var generatedRequestIDs: [UUID] = []
    public private(set) var cancelledAtStep: [UUID: Int] = [:]
    public private(set) var concurrentRuns = 0
    public private(set) var maxConcurrentRuns = 0
    /// Prompts containing a key in this map get the mapped behavior.
    public var behaviorByPrompt: [String: Behavior] = [:]

    private let stepDelay: Duration
    private let outputDirectory: URL
    private var cancelFlags: [UUID: Bool] = [:]
    public private(set) var livePreview: LivePreviewMode = .off

    public func setLivePreview(_ mode: LivePreviewMode) {
        livePreview = mode
    }

    public init(
        id: String = "mock",
        backend: BackendKind = .mlx,
        capabilities: EngineCapabilities = MockEngine.defaultCapabilities,
        stepDelay: Duration = .milliseconds(5),
        outputDirectory: URL
    ) {
        self.id = id
        self.backend = backend
        self.capabilities = capabilities
        self.stepDelay = stepDelay
        self.outputDirectory = outputDirectory
    }

    public static let defaultCapabilities = EngineCapabilities(
        supportedModes: [.textToImage, .imageToImage, .referenceEdit],
        maxReferenceImages: 3,
        supportedResolutions: [512, 1024],
        dimensionMultiple: 32,
        minDimension: 256,
        maxDimension: 2048,
        maxSteps: 50,
        supportsLoRA: false,
        supportsNegativePrompt: false,
        cancellation: .perStep
    )

    public func setBehavior(_ behavior: Behavior, forPromptContaining key: String) {
        behaviorByPrompt[key] = behavior
    }

    public func capabilities(forModel modelID: String) async -> EngineCapabilities? { capabilities }
    public func loadedModelID() async -> String? { loadedModel }

    public func loadModel(id: String) async throws {
        try await Task.sleep(for: stepDelay)
        loadedModel = id
        loadCount += 1
    }

    public func unloadModel() async {
        loadedModel = nil
        unloadCount += 1
    }

    public func cancel(requestID: UUID) async {
        cancelFlags[requestID] = true
    }

    public func generate(request: GenerationRequest) async throws -> AsyncThrowingStream<GenerationEvent, any Error> {
        guard loadedModel == request.modelID else { throw GenerationError.modelNotLoaded }
        generatedRequestIDs.append(request.id)
        cancelFlags[request.id] = false
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: GenerationEvent.self)
        continuation.onTermination = { [weak self] termination in
            if case .cancelled = termination {
                Task { await self?.cancel(requestID: request.id) }
            }
        }
        let behavior = behaviorByPrompt.first { request.prompt.contains($0.key) }?.value ?? .succeed
        Task { await self.run(request, behavior: behavior, continuation: continuation) }
        return stream
    }

    private func run(
        _ request: GenerationRequest,
        behavior: Behavior,
        continuation: AsyncThrowingStream<GenerationEvent, any Error>.Continuation
    ) async {
        concurrentRuns += 1
        maxConcurrentRuns = max(maxConcurrentRuns, concurrentRuns)
        defer { concurrentRuns -= 1 }
        continuation.yield(.preparing)
        for step in 1...request.steps {
            if cancelFlags[request.id] == true {
                cancelledAtStep[request.id] = step
                continuation.finish(throwing: GenerationError.cancelled)
                return
            }
            try? await Task.sleep(for: stepDelay)
            continuation.yield(.step(current: step, total: request.steps))
            if livePreview != .off {
                // 1×1 grey frame whose value encodes the step.
                let v = UInt8(min(255, step))
                continuation.yield(.preview(PreviewFrame(step: step, totalSteps: request.steps, width: 1, height: 1,
                                                         rgba: Data([v, v, v, 255]), isApproximate: livePreview == .approximate)))
            }
        }
        if case .fail(let message) = behavior {
            continuation.finish(throwing: GenerationError.backendFailure(message))
            return
        }
        let url = outputDirectory.appendingPathComponent("\(request.id).png")
        let metadata = GenerationMetadata(request: request, backend: backend.rawValue, inputs: [])
        continuation.yield(.completed(GeneratedImage(fileURL: url, seed: request.seed, elapsedSeconds: 0, metadata: metadata)))
        continuation.finish()
    }
}

/// Memory probe returning a fixed snapshot.
public struct StaticMemoryProbe: SystemMemoryProbe {
    public var value: MemorySnapshot

    public init(_ value: MemorySnapshot) {
        self.value = value
    }

    public static func gb(
        physical: Double = 24, footprint: Double = 1, available: Double = 18,
        pressure: MemoryPressureLevel = .normal, thermal: ThermalLevel = .nominal, gpuCache: Double = 0
    ) -> StaticMemoryProbe {
        StaticMemoryProbe(MemorySnapshot(
            physicalBytes: physical.bytesFromGB, processFootprintBytes: footprint.bytesFromGB,
            systemAvailableBytes: available.bytesFromGB, pressure: pressure, thermal: thermal,
            gpuCacheBytes: gpuCache.bytesFromGB))
    }

    public func snapshot() -> MemorySnapshot { value }
}

/// Memory probe whose snapshots change over time: `snapshots[i]` for the i-th call, the last one after that.
public final class SequenceMemoryProbe: SystemMemoryProbe, @unchecked Sendable {
    private let lock = NSLock()
    private let snapshots: [MemorySnapshot]
    private var calls = 0

    public init(_ probes: [StaticMemoryProbe]) {
        snapshots = probes.map(\.value)
    }

    public var callCount: Int { lock.withLock { calls } }

    public func snapshot() -> MemorySnapshot {
        lock.withLock {
            defer { calls += 1 }
            return snapshots[min(calls, snapshots.count - 1)]
        }
    }
}

public enum TestModels {
    public static func descriptor(
        id: String = "test-model",
        backend: BackendKind = .mlx,
        capabilities: [ModeKind] = [.textToImage, .imageToImage, .referenceEdit],
        maxReferenceImages: Int = 3,
        memory: ModelDescriptor.MemoryProfile? = nil,
        minimumMemoryGB: Double = 8
    ) -> ModelDescriptor {
        ModelDescriptor(
            id: id, name: id, architecture: "test", backend: backend, quantization: "none",
            capabilities: capabilities, maxReferenceImages: maxReferenceImages,
            preferredResolution: 512, supportedResolutions: [512], defaultSteps: 4, defaultGuidance: 1,
            minimumMemoryGB: minimumMemoryGB, memory: memory, license: "test", commercialUse: true)
    }

    public static func request(
        model: String = "test-model",
        mode: GenerationMode = .textToImage,
        inputs: [InputImage] = [],
        prompt: String = "a cat",
        width: Int = 512,
        height: Int = 512,
        steps: Int = 4,
        batchID: UUID? = nil
    ) -> GenerationRequest {
        GenerationRequest(
            modelID: model, mode: mode, inputImages: inputs, prompt: prompt,
            width: width, height: height, steps: steps, guidance: 1, seed: 42, batchID: batchID)
    }
}
