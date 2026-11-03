import CoreGraphics
import Domain
import Flux2Chains
import Flux2Core
import FluxTextEncoders
import Foundation
import Infrastructure
import MLX

/// FLUX.2 (Klein 4B/9B) adapter over the vendored Flux2Core pipeline.
///
/// Verified behaviour (see docs/PROGRESS.md, Etap 1):
/// - text-to-image,
/// - reference edit: images are conditioning tokens (1…N, N from manifest/tests),
/// - image-to-image: one reference + init latents and `strength`.
///
/// Thread-safety: all mutable state is only touched from the owning engine actor,
/// which serializes `load`/`run`/`release`.
public final class Flux2Adapter: MLXPipelineAdapter, @unchecked Sendable {
    public let descriptor: ModelDescriptor
    public let capabilities: EngineCapabilities

    private let model: Flux2Model
    private let quantization: Flux2QuantizationConfig
    private let vaeVariant: ModelRegistry.VAEVariant
    private let memoryOptimization: MemoryOptimizationConfig?
    private let keepTextEncoderLoaded: Bool
    private var pipeline: Flux2Pipeline?
    /// Adapters fused into the currently loaded transformer weights.
    private var activeLoRAs: [LoRAReference] = []

    /// FLUX.2 latent grid: 16px VAE patches packed 2×2 → dimensions multiple of 32.
    public static let dimensionMultiple = 32

    public init(descriptor: ModelDescriptor) throws {
        let opts = descriptor.backendOptions
        guard let model = Flux2Model(rawValue: opts["flux2Model"] ?? "klein-4b") else {
            throw GenerationError.backendFailure("Nieznany wariant FLUX.2: \(opts["flux2Model"] ?? "-")")
        }
        guard let transformerQ = TransformerQuantization(rawValue: opts["transformerQuantization"] ?? descriptor.quantization),
              let textQ = MistralQuantization(rawValue: opts["textEncoderQuantization"] ?? "4bit") else {
            throw GenerationError.backendFailure("Nieznana kwantyzacja w manifeście \(descriptor.id)")
        }
        self.descriptor = descriptor
        self.model = model
        self.quantization = Flux2QuantizationConfig(textEncoder: textQ, transformer: transformerQ)
        self.vaeVariant = ModelRegistry.VAEVariant(rawValue: opts["vaeVariant"] ?? "standard") ?? .standard
        self.memoryOptimization = Self.memoryOptimization(named: opts["memoryOptimization"])
        self.keepTextEncoderLoaded = (opts["keepTextEncoderLoaded"] ?? "true") == "true"
        self.capabilities = descriptor.engineCapabilities(
            cancellation: .perStep,
            dimensionMultiple: Self.dimensionMultiple,
            minDimension: 256,
            maxDimension: 2048,
            maxSteps: 50
        )
    }

    static func memoryOptimization(named name: String?) -> MemoryOptimizationConfig? {
        switch name {
        case "disabled": .disabled
        case "light": .light
        case "moderate": .moderate
        case "aggressive": .aggressive
        case "ultraLow": .ultraLowMemory
        default: nil  // library picks by physical RAM
        }
    }

    private func makePipeline() -> Flux2Pipeline {
        if let existing = pipeline { return existing }
        Flux2Debug.enabled = ProcessInfo.processInfo.environment["NIS_FLUX_DEBUG"] == "1"
        let p = Flux2Pipeline(
            model: model,
            quantization: quantization,
            memoryOptimization: memoryOptimization,
            vaeVariant: vaeVariant
        )
        p.keepTextEncoderLoaded = keepTextEncoderLoaded
        pipeline = p
        return p
    }

    /// Qwen3 text encoder matching the Klein variant and manifest quantization.
    private var qwen3Variant: Qwen3Variant {
        let eightBit = quantization.textEncoder == .mlx8bit || quantization.textEncoder == .bf16
        switch model {
        case .klein9B, .klein9BBase, .klein9BKV: return eightBit ? .qwen3_8B_8bit : .qwen3_8B_4bit
        default: return eightBit ? .qwen3_4B_8bit : .qwen3_4B_4bit
        }
    }

    /// Transformer weights owned by this model; VAE and the Qwen3 encoder are shared
    /// across Klein variants and are kept on removal.
    public var ownedWeightsURL: URL? {
        let variant = ModelRegistry.TransformerVariant.variant(for: model, quantization: quantization.transformer)
        return Flux2ModelDownloader.findModelPath(for: .transformer(variant))
    }

    public var sharedComponents: [String] { ["VAE FLUX.2", "Qwen3 text encoder (\(qwen3Variant.rawValue))"] }

    public func isInstalled() -> Bool {
        makePipeline().hasRequiredModels && TextEncoderModelDownloader.isQwen3ModelDownloaded(variant: qwen3Variant)
    }

    /// Transformer + VAE (Flux2 downloader) and the Qwen3 text encoder, so that
    /// later runs need no network at all.
    public func prepareWeights(progress: (@Sendable (Double, String) -> Void)?) async throws {
        let p = makePipeline()
        try await p.loadModels { fraction, message in progress?(fraction * 0.7, message) }
        _ = try await TextEncoderModelDownloader().downloadQwen3(variant: qwen3Variant) { fraction, message in
            progress?(0.7 + fraction * 0.3, message)
        }
    }

    public func load() async throws {
        let p = makePipeline()
        if !p.hasRequiredModels {
            throw GenerationError.modelNotFound("\(descriptor.name): brak wag lokalnie (\(p.missingModels.map(\.displayName).joined(separator: ", "))). Pobierz model w zakładce Modele.")
        }
        try await p.loadModels()
        try await p.preload()
    }

    /// Flux2Core fuses LoRA weights into the transformer at load time and cannot un-fuse
    /// them, so a different adapter set means reloading the pipeline (weights come from
    /// the OS file cache; measured in docs/PROGRESS.md, Etap 4).
    func applyLoRAs(_ loras: [LoRAReference]) async throws {
        guard loras != activeLoRAs else { return }
        if let old = pipeline {
            await old.clearAll()
            pipeline = nil
        }
        let p = makePipeline()
        do {
            for lora in loras {
                guard FileManager.default.fileExists(atPath: lora.fileURL.path) else {
                    throw GenerationError.inputProcessingFailed("Brak pliku LoRA: \(lora.fileURL.lastPathComponent)")
                }
                _ = try p.loadLoRA(LoRAConfig(filePath: lora.fileURL.path, scale: lora.scale, activationKeyword: lora.triggerWord))
            }
            try await p.loadModels()
            try await p.preload()
        } catch {
            // Leave a clean, LoRA-free pipeline behind.
            await p.clearAll()
            pipeline = nil
            activeLoRAs = []
            try await load()
            throw (error as? GenerationError) ?? GenerationError.backendFailure("LoRA: \(error.localizedDescription)")
        }
        activeLoRAs = loras
    }

    public func run(_ request: GenerationRequest, inputs: PreparedInputs, callbacks: PipelineCallbacks) async throws -> CGImage {
        try await applyLoRAs(request.loras)
        guard let p = pipeline else { throw GenerationError.modelNotLoaded }
        p.cancellationHandler = callbacks.isCancelled
        defer { p.cancellationHandler = nil }
        let onProgress: Flux2ProgressCallback = { current, total in callbacks.onStep(current, total) }
        // Packed latents [1, (H/16)·(W/16), 128] are already positions × channels. The noisy
        // latents of a distilled 4-step run are mostly noise until the end, so the preview shows the
        // denoised estimate x̂₀ = x − σ·v, with v recovered from two consecutive Euler states
        // (x_next = x + (σ_next − σ)·v). The first step has no previous state and is skipped.
        // Full decode runs x̂₀ through the VAE every few steps (not the last one: the result is
        // decoded anyway).
        let fullDecode = callbacks.livePreview == .fullDecode
        var onStepHook: Flux2StepHook?
        if callbacks.wantsLatents || fullDecode {
            let previous = LatentBox()
            onStepHook = { @Sendable ctx, latents in
                defer { previous.value = latents }
                guard let before = previous.value, ctx.sigmaNext != ctx.sigma else { return latents }
                let velocity = (latents - before) / (ctx.sigmaNext - ctx.sigma)
                let denoised = latents - ctx.sigmaNext * velocity
                let step = ctx.stepIdx + 1
                if fullDecode {
                    if step < ctx.totalSteps, step % LatentPreview.fullDecodeInterval(steps: ctx.totalSteps) == 0,
                       let image = p.decodePackedLatentsForPreview(denoised, height: ctx.height, width: ctx.width) {
                        callbacks.report(decoded: image, step: step, total: ctx.totalSteps)
                    }
                } else {
                    let values: [Float] = denoised[0].asType(.float32).asArray(Float.self)
                    callbacks.report(LatentGrid(step: step, totalSteps: ctx.totalSteps,
                                                gridWidth: ctx.width / 16, gridHeight: ctx.height / 16,
                                                channels: latents.shape[2], values: values))
                }
                return latents
            }
        }

        do {
            let result: Flux2GenerationResult
            switch request.mode {
            case .textToImage:
                result = try await p.generateWithResult(
                    mode: .textToImage, prompt: request.prompt,
                    height: request.height, width: request.width,
                    steps: request.steps, guidance: request.guidance, seed: request.seed,
                    upsamplePrompt: false, checkpointInterval: nil,
                    onProgress: onProgress, onCheckpoint: nil, onStep: onStepHook)

            case .referenceEdit:
                result = try await p.generateWithResult(
                    mode: .imageToImage(images: inputs.images), prompt: request.prompt,
                    height: request.height, width: request.width,
                    steps: request.steps, guidance: request.guidance, seed: request.seed,
                    upsamplePrompt: false, checkpointInterval: nil,
                    onProgress: onProgress, onCheckpoint: nil, onStep: onStepHook)

            case .imageToImage(let strength):
                guard let source = inputs.images.first else { throw GenerationError.inputProcessingFailed("brak obrazu") }
                let effective = Self.effectiveStrength(strength, steps: request.steps)
                // Strength 1.0 = pure reference conditioning (no init anchor).
                let initLatents: MLXArray? = effective < 1
                    ? try await p.encodeImageToPackedSequence(source, targetHeight: request.height, targetWidth: request.width)
                    : nil
                result = try await p.generateWithResult(
                    mode: .imageToImage(images: [source]), prompt: request.prompt,
                    height: request.height, width: request.width,
                    steps: request.steps, guidance: request.guidance, seed: request.seed,
                    upsamplePrompt: false, checkpointInterval: nil,
                    initLatents: initLatents, strength: effective,
                    onProgress: onProgress, onCheckpoint: nil, onStep: onStepHook)

            case .inpainting:
                guard let source = inputs.images.first, let mask = inputs.mask else {
                    throw GenerationError.inputProcessingFailed("Inpainting wymaga obrazu i maski.")
                }
                // RePaint-style chain: masked region regenerated, the rest composited back
                // from the original pixels (bit-identical outside the mask).
                let chain = Flux2MaskedInpaintingChain(
                    pipeline: p, prompt: request.prompt, image: source, mask: mask,
                    steps: request.steps, guidance: request.guidance, seed: request.seed,
                    strength: 1.0, compositeOnOriginal: true,
                    maxPixels: request.width * request.height, onProgress: onProgress)
                result = try await chain.run()
            }
            return result.image
        } catch let error as Flux2Error {
            if case .generationCancelled = error { throw GenerationError.cancelled }
            throw GenerationError.backendFailure(error.localizedDescription)
        }
    }

    /// The scheduler needs at least one denoising step: strength ≥ 1/steps.
    static func effectiveStrength(_ strength: Float, steps: Int) -> Float {
        min(1, max(strength, 1 / Float(max(1, steps))))
    }

    public var supportsFullDecodePreview: Bool { true }

    public func release() async {
        guard let p = pipeline else { return }
        p.cancellationHandler = nil
        await p.clearAll()
        pipeline = nil
        activeLoRAs = []
    }
}

/// Previous step's latents for the FLUX.2 preview hook (called serially from the denoise loop).
private final class LatentBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: MLXArray?
    var value: MLXArray? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
