import Foundation

/// Inference backend family.
public enum BackendKind: String, Sendable, Hashable, Codable, CaseIterable {
    case mlx
    case coreml
}

/// Model manifest (`<model>.json`). Values come from verification/measurement,
/// see docs/PROGRESS.md for their source.
public struct ModelDescriptor: Sendable, Hashable, Codable, Identifiable {
    /// Memory cost model used by MemoryBudgetManager. Measured, not guessed.
    public struct MemoryProfile: Sendable, Hashable, Codable {
        /// Resident footprint after load (weights + encoders kept in memory), GB.
        public var residentGB: Double
        /// Additional peak during inference at 1 MP output, GB.
        public var activationGBPerMegapixel: Double
        /// Additional peak per reference image at 1 MP, GB.
        public var perReferenceImageGB: Double

        public init(residentGB: Double, activationGBPerMegapixel: Double, perReferenceImageGB: Double) {
            self.residentGB = residentGB
            self.activationGBPerMegapixel = activationGBPerMegapixel
            self.perReferenceImageGB = perReferenceImageGB
        }
    }

    public let id: String
    public var name: String
    /// Adapter family, e.g. "flux2", "sdxl", "zimage".
    public var architecture: String
    public var backend: BackendKind
    public var quantization: String
    public var capabilities: [ModeKind]
    public var maxReferenceImages: Int
    public var preferredResolution: Int
    public var supportedResolutions: [Int]
    public var defaultSteps: Int
    public var defaultGuidance: Float
    /// Application safety threshold (configurable), not a vendor requirement.
    public var minimumMemoryGB: Double
    public var memory: MemoryProfile?
    public var license: String
    public var commercialUse: Bool
    public var knownLimitations: [String]
    public var supportsLoRA: Bool
    public var supportsNegativePrompt: Bool
    /// Backend-specific options (e.g. HF repo, variant, local resource path).
    public var backendOptions: [String: String]
    /// Prompt convention for the prompt assistant; nil → derived (see `effectivePromptStyle`).
    public var promptStyle: PromptStyle?

    public init(
        id: String,
        name: String,
        architecture: String,
        backend: BackendKind,
        quantization: String,
        capabilities: [ModeKind],
        maxReferenceImages: Int,
        preferredResolution: Int,
        supportedResolutions: [Int],
        defaultSteps: Int,
        defaultGuidance: Float,
        minimumMemoryGB: Double,
        memory: MemoryProfile? = nil,
        license: String,
        commercialUse: Bool,
        knownLimitations: [String] = [],
        supportsLoRA: Bool = false,
        supportsNegativePrompt: Bool = false,
        backendOptions: [String: String] = [:],
        promptStyle: PromptStyle? = nil
    ) {
        self.id = id
        self.name = name
        self.architecture = architecture
        self.backend = backend
        self.quantization = quantization
        self.capabilities = capabilities
        self.maxReferenceImages = maxReferenceImages
        self.preferredResolution = preferredResolution
        self.supportedResolutions = supportedResolutions
        self.defaultSteps = defaultSteps
        self.defaultGuidance = defaultGuidance
        self.minimumMemoryGB = minimumMemoryGB
        self.memory = memory
        self.license = license
        self.commercialUse = commercialUse
        self.knownLimitations = knownLimitations
        self.supportsLoRA = supportsLoRA
        self.supportsNegativePrompt = supportsNegativePrompt
        self.backendOptions = backendOptions
        self.promptStyle = promptStyle
    }

    /// Capabilities as seen by the UI and the validator.
    public func engineCapabilities(
        cancellation: CancellationGranularity,
        dimensionMultiple: Int = 16,
        minDimension: Int = 256,
        maxDimension: Int = 2048,
        maxSteps: Int = 100
    ) -> EngineCapabilities {
        EngineCapabilities(
            supportedModes: Set(capabilities),
            maxReferenceImages: capabilities.contains(.referenceEdit) ? maxReferenceImages : 0,
            supportedResolutions: supportedResolutions,
            dimensionMultiple: dimensionMultiple,
            minDimension: minDimension,
            maxDimension: maxDimension,
            maxSteps: maxSteps,
            supportsLoRA: supportsLoRA,
            supportsNegativePrompt: supportsNegativePrompt,
            cancellation: cancellation
        )
    }

    /// Core ML model run on the Neural Engine (the default compute units). The system compiles
    /// it for the ANE on load and keeps only a few compiled SDXL models: switching between them
    /// recompiles (measured 60–123 s on M4 Pro, docs/PROGRESS.md).
    public var compilesForNeuralEngine: Bool {
        backend == .coreml && !["cpuAndGPU", "cpuOnly"].contains(backendOptions["computeUnits"] ?? "")
    }
}
