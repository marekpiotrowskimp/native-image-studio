import CoreGraphics
import Domain
import Foundation
import Infrastructure

/// Inputs already decoded, oriented and converted to sRGB (prepared off the main actor).
public struct PreparedInputs: @unchecked Sendable {
    /// Images in request order (CGImage is immutable).
    public let images: [CGImage]
    public let mask: CGImage?

    public init(images: [CGImage], mask: CGImage? = nil) {
        self.images = images
        self.mask = mask
    }
}

/// Callbacks from the pipeline into the engine. Must be cheap: called from the
/// inference thread between steps.
public struct PipelineCallbacks: Sendable {
    public let onStep: @Sendable (_ current: Int, _ total: Int) -> Void
    public let isCancelled: @Sendable () -> Bool
    /// What the adapter should report as previews.
    public let livePreview: LivePreviewMode
    /// Latent→RGB map of this model's VAE (nil: no approximate previews).
    public let previewFactors: LatentRGBFactors?
    public let onPreview: @Sendable (PreviewFrame) -> Void

    public init(onStep: @escaping @Sendable (Int, Int) -> Void, isCancelled: @escaping @Sendable () -> Bool,
                livePreview: LivePreviewMode = .off, previewFactors: LatentRGBFactors? = nil,
                onPreview: @escaping @Sendable (PreviewFrame) -> Void = { _ in }) {
        self.onStep = onStep
        self.isCancelled = isCancelled
        self.livePreview = livePreview
        self.previewFactors = previewFactors
        self.onPreview = onPreview
    }

    /// Whether the adapter should hand latents over at all (approximate previews or the fit tap).
    public var wantsLatents: Bool {
        (livePreview == .approximate && previewFactors != nil) || LatentPreview.tap != nil
    }

    /// Step latents from the adapter: to the fit tap, and as an approximate preview.
    public func report(_ grid: LatentGrid) {
        LatentPreview.tap?(grid)
        guard livePreview == .approximate, let factors = previewFactors,
              let frame = LatentPreview.frame(grid, factors: factors) else { return }
        onPreview(frame)
    }

    /// A decoded intermediate image (full-decode previews).
    public func report(decoded image: CGImage, step: Int, total: Int) {
        if let frame = LatentPreview.frame(image, step: step, totalSteps: total) { onPreview(frame) }
    }
}

/// One adapter per model family (no universal .safetensors loader).
public protocol MLXPipelineAdapter: AnyObject, Sendable {
    var descriptor: ModelDescriptor { get }
    /// Capabilities verified for this family/model.
    var capabilities: EngineCapabilities { get }
    /// All weights needed for offline use are on disk.
    func isInstalled() -> Bool
    /// Weights that belong only to this model (deleted on removal).
    var ownedWeightsURL: URL? { get }
    /// Components kept on removal because other models use them.
    var sharedComponents: [String] { get }
    /// Download missing weights (no-op when present).
    func prepareWeights(progress: (@Sendable (Double, String) -> Void)?) async throws
    /// Load weights into memory.
    func load() async throws
    /// Run one request. Throws `GenerationError.cancelled` at a safe point when cancelled.
    func run(_ request: GenerationRequest, inputs: PreparedInputs, callbacks: PipelineCallbacks) async throws -> CGImage
    /// Drop all references to weights and pipeline state.
    func release() async
    /// The pipeline can decode intermediate latents with its VAE (`LivePreviewMode.fullDecode`).
    var supportsFullDecodePreview: Bool { get }
}

public extension MLXPipelineAdapter {
    var supportsFullDecodePreview: Bool { false }
}
