import Foundation

/// How fine-grained cancellation is inside an engine.
public enum CancellationGranularity: String, Sendable, Hashable, Codable {
    /// Only before inference starts.
    case beforeStart
    /// Checked between denoising steps.
    case perStep
}

/// What a model (served by a specific engine) can do. UI shows only these modes.
public struct EngineCapabilities: Sendable, Hashable, Codable {
    public var supportedModes: Set<ModeKind>
    /// Max reference images for `.referenceEdit` (from model verification, not assumptions).
    public var maxReferenceImages: Int
    /// Preferred square edge sizes offered in the UI (e.g. [512, 768, 1024]).
    public var supportedResolutions: [Int]
    /// Output width/height must be a multiple of this value.
    public var dimensionMultiple: Int
    public var minDimension: Int
    public var maxDimension: Int
    /// Fewer steps than this crash or break the backend's scheduler (Core ML DPM-Solver++ with
    /// Karras spacing divides by zero at 1 step).
    public var minSteps: Int
    public var maxSteps: Int
    public var supportsLoRA: Bool
    public var supportsNegativePrompt: Bool
    public var cancellation: CancellationGranularity

    public init(
        supportedModes: Set<ModeKind>,
        maxReferenceImages: Int,
        supportedResolutions: [Int],
        dimensionMultiple: Int = 16,
        minDimension: Int = 256,
        maxDimension: Int = 2048,
        minSteps: Int = 1,
        maxSteps: Int = 100,
        supportsLoRA: Bool,
        supportsNegativePrompt: Bool,
        cancellation: CancellationGranularity
    ) {
        self.supportedModes = supportedModes
        self.maxReferenceImages = maxReferenceImages
        self.supportedResolutions = supportedResolutions
        self.dimensionMultiple = dimensionMultiple
        self.minDimension = minDimension
        self.maxDimension = maxDimension
        self.minSteps = minSteps
        self.maxSteps = maxSteps
        self.supportsLoRA = supportsLoRA
        self.supportsNegativePrompt = supportsNegativePrompt
        self.cancellation = cancellation
    }

    public func supports(_ mode: ModeKind) -> Bool { supportedModes.contains(mode) }

    public var stepRange: ClosedRange<Int> { minSteps...max(minSteps, maxSteps) }
}
