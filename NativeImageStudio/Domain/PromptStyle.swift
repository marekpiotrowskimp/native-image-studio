import Foundation

/// How an image model expects its prompt to be written. The prompt assistant writes in this style.
public enum PromptStyle: String, Sendable, Hashable, Codable, CaseIterable {
    /// Full sentences (FLUX.2, Z-Image: LLM text encoders).
    case naturalLanguage
    /// Comma-separated descriptive phrases (photographic SDXL fine-tunes, CLIP encoders).
    case sdxlPhrases
    /// Pony Diffusion: `score_*` quality prefix, `source_*` tag, then tags.
    case ponyTags
    /// Danbooru-style tags (Illustrious / NoobAI derivatives).
    case booruTags
}

public extension ModelDescriptor {
    /// Manifest `promptStyle`, else derived from the architecture.
    var effectivePromptStyle: PromptStyle {
        if let promptStyle { return promptStyle }
        return architecture == "sdxl" ? .sdxlPhrases : .naturalLanguage
    }
}
