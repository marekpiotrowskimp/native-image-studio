import Foundation

/// A LoRA adapter applied on top of the base model.
public struct LoRAReference: Sendable, Hashable, Codable {
    public let fileURL: URL
    public let scale: Float
    public let triggerWord: String?

    public init(fileURL: URL, scale: Float = 1.0, triggerWord: String? = nil) {
        self.fileURL = fileURL
        self.scale = scale
        self.triggerWord = triggerWord
    }
}

/// One unit of work for an engine. Backend-agnostic.
public struct GenerationRequest: Sendable, Hashable, Codable, Identifiable {
    public let id: UUID
    public let modelID: String
    public let mode: GenerationMode
    /// Empty for `.textToImage`. Order matters: "image 1", "image 2"… in the prompt.
    public let inputImages: [InputImage]
    public let prompt: String
    public let negativePrompt: String?
    public let width: Int
    public let height: Int
    public let steps: Int
    public let guidance: Float
    public let seed: UInt64
    public let batchID: UUID?
    public let resizeMode: ResizeMode
    public let loras: [LoRAReference]

    public init(
        id: UUID = UUID(),
        modelID: String,
        mode: GenerationMode,
        inputImages: [InputImage] = [],
        prompt: String,
        negativePrompt: String? = nil,
        width: Int,
        height: Int,
        steps: Int,
        guidance: Float,
        seed: UInt64,
        batchID: UUID? = nil,
        resizeMode: ResizeMode = .crop,
        loras: [LoRAReference] = []
    ) {
        self.id = id
        self.modelID = modelID
        self.mode = mode
        self.inputImages = inputImages
        self.prompt = prompt
        self.negativePrompt = negativePrompt
        self.width = width
        self.height = height
        self.steps = steps
        self.guidance = guidance
        self.seed = seed
        self.batchID = batchID
        self.resizeMode = resizeMode
        self.loras = loras
    }

    /// Copy with a different identity/inputs, used to fan a batch out into jobs.
    public func with(
        id: UUID = UUID(),
        inputImages: [InputImage]? = nil,
        seed: UInt64? = nil,
        batchID: UUID?? = nil,
        width: Int? = nil,
        height: Int? = nil
    ) -> GenerationRequest {
        GenerationRequest(
            id: id,
            modelID: modelID,
            mode: mode,
            inputImages: inputImages ?? self.inputImages,
            prompt: prompt,
            negativePrompt: negativePrompt,
            width: width ?? self.width,
            height: height ?? self.height,
            steps: steps,
            guidance: guidance,
            seed: seed ?? self.seed,
            batchID: batchID ?? self.batchID,
            resizeMode: resizeMode,
            loras: loras
        )
    }

    /// All image files the request reads (inputs + inpainting mask).
    public var allImageFiles: [URL] {
        var urls = inputImages.map(\.sourceURL)
        if case .inpainting(let mask) = mode { urls.append(mask.sourceURL) }
        return urls
    }

    public var primaryImage: InputImage? {
        inputImages.first { $0.role == .primary } ?? inputImages.first
    }
}
