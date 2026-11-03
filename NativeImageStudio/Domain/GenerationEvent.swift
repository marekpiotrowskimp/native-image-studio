import Foundation

/// Provenance stored next to every generated file.
public struct GenerationMetadata: Sendable, Hashable, Codable {
    public struct InputRecord: Sendable, Hashable, Codable {
        public let path: String
        public let sha256: String
        public let role: InputImage.Role

        public init(path: String, sha256: String, role: InputImage.Role) {
            self.path = path
            self.sha256 = sha256
            self.role = role
        }
    }

    public let requestID: UUID
    public let prompt: String
    public let negativePrompt: String?
    public let mode: GenerationMode
    public let modelID: String
    public let backend: String
    public let width: Int
    public let height: Int
    public let steps: Int
    public let guidance: Float
    public let seed: UInt64
    public let inputs: [InputRecord]
    public let batchID: UUID?
    public let createdAt: Date

    public init(
        request: GenerationRequest,
        backend: String,
        inputs: [InputRecord],
        createdAt: Date = Date()
    ) {
        self.requestID = request.id
        self.prompt = request.prompt
        self.negativePrompt = request.negativePrompt
        self.mode = request.mode
        self.modelID = request.modelID
        self.backend = backend
        self.width = request.width
        self.height = request.height
        self.steps = request.steps
        self.guidance = request.guidance
        self.seed = request.seed
        self.inputs = inputs
        self.batchID = request.batchID
        self.createdAt = createdAt
    }
}

/// Engine measurements of one run (for the benchmark panel).
public struct RunStats: Sendable, Hashable, Codable {
    /// Denoising time per step (first→last step callback), nil if < 2 steps ran.
    public let secondsPerStep: Double?
    /// Backend allocator peak (MLX) or process peak footprint (Core ML), GB.
    public let peakMemoryGB: Double
    public let peakMemorySource: String
    public let thermalState: String

    public init(secondsPerStep: Double?, peakMemoryGB: Double, peakMemorySource: String, thermalState: String) {
        self.secondsPerStep = secondsPerStep
        self.peakMemoryGB = peakMemoryGB
        self.peakMemorySource = peakMemorySource
        self.thermalState = thermalState
    }
}

/// A finished image written to disk (never over an input file).
public struct GeneratedImage: Sendable, Hashable, Codable {
    public let fileURL: URL
    public let seed: UInt64
    public let elapsedSeconds: Double
    public let metadata: GenerationMetadata
    public let stats: RunStats?

    public init(fileURL: URL, seed: UInt64, elapsedSeconds: Double, metadata: GenerationMetadata, stats: RunStats? = nil) {
        self.fileURL = fileURL
        self.seed = seed
        self.elapsedSeconds = elapsedSeconds
        self.metadata = metadata
        self.stats = stats
    }
}

/// Progress stream emitted by an engine for one request.
public enum GenerationEvent: Sendable, Equatable {
    case preparing
    case preprocessingInputs
    case loadingModel
    case step(current: Int, total: Int)
    /// Intermediate image after a denoising step (see `LivePreviewMode`).
    case preview(PreviewFrame)
    case decoding
    case completed(GeneratedImage)
}

/// Engine-level failures (backend-agnostic).
public enum GenerationError: Error, Sendable, Equatable, LocalizedError {
    /// The engine reached a safe stop point after cancellation was requested.
    case cancelled
    case modelNotFound(String)
    case modelNotLoaded
    case insufficientMemory(requiredGB: Double, availableGB: Double, detail: String)
    case thermalThrottling(String)
    case inputProcessingFailed(String)
    case backendFailure(String)

    public var errorDescription: String? {
        switch self {
        case .cancelled: "Generowanie anulowane."
        case .modelNotFound(let id): "Nie znaleziono modelu \(id)."
        case .modelNotLoaded: "Model nie jest załadowany."
        case .insufficientMemory(let req, let avail, let detail):
            String(format: "Za mało pamięci: potrzeba ~%.1f GB, dostępne ~%.1f GB. %@", req, avail, detail)
        case .thermalThrottling(let msg): msg
        case .inputProcessingFailed(let msg): "Błąd przetwarzania obrazu wejściowego: \(msg)"
        case .backendFailure(let msg): "Błąd silnika: \(msg)"
        }
    }
}
