import CoreGraphics
import CoreML
import Domain
import Foundation
import Infrastructure
import StableDiffusion

/// SDXL adapter over apple/ml-stable-diffusion. The pipeline object is not Sendable;
/// all access is serialized by `CoreMLGenerationEngine` (one run at a time).
final class SDXLPipelineAdapter: @unchecked Sendable {
    let descriptor: ModelDescriptor
    private var pipeline: StableDiffusionXLPipeline?

    /// Default when a model's resources are not installed yet (most SDXL conversions).
    static let fixedResolution = 1024

    /// The converted UNet has a fixed latent size: read it from the model, else the manifest.
    static func resolution(for d: ModelDescriptor) -> Int {
        CoreMLModelLoader.nativeResolution(d) ?? d.preferredResolution
    }

    init(descriptor: ModelDescriptor) {
        self.descriptor = descriptor
    }

    static func capabilities(for d: ModelDescriptor, hasEncoder: Bool) -> EngineCapabilities {
        var modes = Set(d.capabilities).intersection([.textToImage, .imageToImage])
        if !hasEncoder { modes.remove(.imageToImage) }
        let size = resolution(for: d)
        return EngineCapabilities(
            supportedModes: modes,
            maxReferenceImages: 0,
            supportedResolutions: [size],
            dimensionMultiple: 8,
            minDimension: size,
            maxDimension: size,
            minSteps: 2,
        maxSteps: 50,
            supportsLoRA: false,
            supportsNegativePrompt: true,
            cancellation: .perStep)
    }

    func load() throws {
        let dir = CoreMLModelLoader.resourceDirectory(for: descriptor)
        let config = MLModelConfiguration()
        config.computeUnits = CoreMLModelLoader.computeUnits(descriptor)
        let p = try StableDiffusionXLPipeline(
            resourcesAt: dir, configuration: config,
            reduceMemory: descriptor.backendOptions["reduceMemory"] == "true")
        try p.loadResources()
        pipeline = p
    }

    /// Runs synchronously on the calling (non-main) thread.
    func run(_ request: GenerationRequest, startingImage: CGImage?, flag: CancellationFlag,
             preview: CoreMLPreviewSink = CoreMLPreviewSink(),
             onStep: @escaping @Sendable (Int, Int) -> Void) throws -> CGImage {
        guard let pipeline else { throw GenerationError.modelNotLoaded }
        var config = StableDiffusionXLPipeline.Configuration(prompt: request.prompt)
        config.negativePrompt = request.negativePrompt ?? ""
        config.stepCount = request.steps
        config.guidanceScale = request.guidance
        // The Core ML pipeline takes a 32-bit seed.
        config.seed = UInt32(truncatingIfNeeded: request.seed)
        config.imageCount = 1
        config.schedulerType = Self.scheduler(descriptor.backendOptions["scheduler"])
        config.schedulerTimestepSpacing = Self.spacing(descriptor.backendOptions["timestepSpacing"])
        config.rngType = .numpyRNG
        config.encoderScaleFactor = 0.13025
        config.decoderScaleFactor = 0.13025
        config.originalSize = Float32(request.width)
        config.targetSize = Float32(request.width)
        // Previews show the scheduler's denoised estimate (x̂₀) rather than the noisy latents;
        // the final image is decoded from the denoised latents either way.
        config.useDenoisedIntermediates = preview.mode != .off || LatentPreview.tap != nil
        if case .imageToImage(let strength) = request.mode {
            config.startingImage = startingImage
            config.strength = strength
        }
        let images = try pipeline.generateImages(configuration: config) { progress in
            onStep(progress.step + 1, progress.stepCount)
            preview.report(progress)
            return !flag.isCancelled
        }
        if flag.isCancelled { throw GenerationError.cancelled }
        guard let image = images.first ?? nil else {
            throw GenerationError.backendFailure("Pipeline Core ML nie zwrócił obrazu.")
        }
        return image
    }

    func release() {
        pipeline?.unloadResources()
        pipeline = nil
    }

    static func scheduler(_ name: String?) -> StableDiffusionScheduler {
        switch name {
        case "pndm": .pndmScheduler
        default: .dpmSolverMultistepScheduler
        }
    }

    static func spacing(_ name: String?) -> TimeStepSpacing {
        switch name {
        case "linspace": .linspace
        case "leading": .leading
        default: .karras
        }
    }
}

/// Live previews from the Core ML pipeline's progress callback.
struct CoreMLPreviewSink: Sendable {
    var mode: LivePreviewMode = .off
    /// SDXL VAE latent→RGB map (nil: no approximate previews).
    var factors: LatentRGBFactors?
    var onPreview: @Sendable (PreviewFrame) -> Void = { _ in }

    func report(_ progress: StableDiffusionXLPipeline.Progress) {
        let step = progress.step + 1
        let total = progress.stepCount
        let wantsLatents = (mode == .approximate && factors != nil) || LatentPreview.tap != nil
        if wantsLatents, let latent = progress.currentLatentSamples.first, latent.shape.count == 4 {
            // [1, 4, H/8, W/8]
            let shape = latent.shape
            let grid = LatentGrid.fromCHW(latent.scalars, channels: shape[1], width: shape[3], height: shape[2],
                                          step: step, totalSteps: total)
            LatentPreview.tap?(grid)
            if mode == .approximate, let factors, let frame = LatentPreview.frame(grid, factors: factors) {
                onPreview(frame)
            }
        }
        // The last step is decoded anyway for the result.
        if mode == .fullDecode, step < total, step % LatentPreview.fullDecodeInterval(steps: total) == 0,
           let image = progress.currentImages.first ?? nil,
           let frame = LatentPreview.frame(image, step: step, totalSteps: total) {
            onPreview(frame)
        }
    }
}
