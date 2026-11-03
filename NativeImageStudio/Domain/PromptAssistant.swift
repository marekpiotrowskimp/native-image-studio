import Foundation

/// What the prompt assistant should write.
public struct PromptDraftRequest: Sendable, Equatable {
    /// Scene idea in any language (typically Polish); may be empty when only refining.
    public var idea: String
    /// Prompt already in the editor; when set, the assistant refines it instead of starting over.
    public var currentPrompt: String?
    public var style: PromptStyle

    public init(idea: String, currentPrompt: String? = nil, style: PromptStyle) {
        self.idea = idea
        self.currentPrompt = currentPrompt
        self.style = style
    }
}

public enum PromptAssistantEvent: Sendable, Equatable {
    /// An image generation holds the GPU; the assistant starts when it finishes.
    case waitingForGPU
    case loadingModel
    /// Cleaned prompt so far.
    case partial(String)
    case finished(String)
}

/// Local LLM that turns a scene idea into a prompt for the selected image model.
public protocol PromptWriting: Sendable {
    var modelName: String { get }
    var downloadSizeBytes: Int64 { get }
    func isInstalled() async -> Bool
    func install(progress: (@Sendable (Double, String) -> Void)?) async throws
    func remove() async throws
    func write(_ request: PromptDraftRequest) async -> AsyncThrowingStream<PromptAssistantEvent, any Error>
}

/// System and user messages for the assistant. Kept free of model specifics so it can be tested.
public enum PromptInstructions {
    public static let ponyPrefix = "score_9, score_8_up, score_7_up, score_6_up, score_5_up, score_4_up"
    public static let booruPrefix = "masterpiece, best quality, amazing quality"

    public static func system(for style: PromptStyle) -> String {
        """
        You write prompts for a text-to-image model. Turn the user's scene idea into a realistic, \
        concrete, visual description. The idea may be in Polish or another language; always write \
        the prompt in English.

        Describe only what a camera would see: the main subject first (appearance, build, clothing \
        and its materials, expression, pose, action), then the setting and background, time of day \
        and weather, lighting (direction, softness, colour temperature), camera and composition \
        (shot type, angle, lens focal length, depth of field) and the overall colour palette and \
        textures. Keep every detail the user gave and never contradict it; add plausible details \
        where the idea is vague. Prefer physically plausible, natural-looking scenes over fantasy \
        unless the user asks for it. Describe only what is present: never use negations such as \
        "no text" or "without people", and leave out sounds, smells and feelings a camera cannot see. \
        Every person described is an adult.

        \(styleRules(style))

        Reply with the prompt only: one paragraph, no title, no quotes, no explanations, no markdown.
        """
    }

    static func styleRules(_ style: PromptStyle) -> String {
        switch style {
        case .naturalLanguage:
            "Format: flowing natural sentences, 60–120 words, written like the description of a real photograph."
        case .sdxlPhrases:
            "Format: short comma-separated phrases of two to six words, most important first, 30–45 words in total: the text encoder ignores everything after about 75 tokens. Start with the medium, e.g. \"raw photo\" or \"35mm film photo\", and include camera and lighting phrases."
        case .ponyTags:
            "Format: short comma-separated tags, 20–30 words after the prefix. Begin exactly with \"\(ponyPrefix), \" followed by exactly one of these source tags: source_anime (default), source_cartoon, source_furry, source_pony. Then subject, clothing, pose, setting and lighting tags."
        case .booruTags:
            "Format: 15–30 lowercase Danbooru tags separated by commas. Begin exactly with \"\(booruPrefix), \" then a character count tag such as 1girl, 1boy or 2girls, then appearance, clothing, pose, setting, lighting and composition tags."
        }
    }

    public static func user(for request: PromptDraftRequest) -> String {
        let idea = request.idea.trimmingCharacters(in: .whitespacesAndNewlines)
        let current = request.currentPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch (idea.isEmpty, current.isEmpty) {
        case (_, true):
            return "Scene idea: \(idea)"
        case (true, false):
            return "Rewrite and enrich this prompt, keeping its subject and intent:\n\(current)"
        case (false, false):
            return "Current prompt:\n\(current)\n\nRewrite it in full, applying this change: \(idea)"
        }
    }
}

/// Turns raw model output into a usable prompt.
public enum PromptCleaner {
    /// `final: false` while streaming: the quality prefix is only enforced on the finished text,
    /// since a partial one ("score_9, sc") would otherwise be duplicated.
    public static func clean(_ raw: String, style: PromptStyle, final: Bool = true) -> String {
        var text = stripThinking(raw)
        text = text.replacingOccurrences(of: "```", with: "")
        text = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        for label in ["Prompt:", "prompt:", "PROMPT:", "**Prompt:**"] where text.hasPrefix(label) {
            text = String(text.dropFirst(label.count))
        }
        text = text.trimmingCharacters(in: .whitespaces)
        let quotes: Set<Character> = ["\"", "“", "”", "'", "`"]
        while let first = text.first, let last = text.last, text.count > 1, quotes.contains(first), quotes.contains(last) {
            text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        guard final else { return text }
        return limitWords(ensurePrefix(tidyTags(text, style: style), style: style), style: style)
    }

    /// CLIP-encoded models (SDXL) read about 75 tokens; longer prompts are silently cut. Keep the
    /// most important (leading) phrases, cutting at a phrase boundary.
    public static func wordBudget(_ style: PromptStyle) -> Int? {
        switch style {
        case .naturalLanguage: nil
        case .sdxlPhrases: 55
        case .ponyTags: 50
        case .booruTags: 45
        }
    }

    static func limitWords(_ text: String, style: PromptStyle) -> String {
        guard let budget = wordBudget(style) else { return text }
        let words = text.split(separator: " ", omittingEmptySubsequences: true)
        guard words.count > budget else { return text }
        let head = words.prefix(budget).joined(separator: " ")
        guard let comma = head.lastIndex(of: ",") else { return head }
        return String(head[..<comma])
    }

    /// Tag styles: no trailing full stop, no echoed length hints ("50 words"), and a comma
    /// after the quality prefix.
    static func tidyTags(_ text: String, style: PromptStyle) -> String {
        guard style != .naturalLanguage else { return text }
        var tags = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        tags.removeAll { $0.isEmpty || $0.range(of: #"^\d+(\s*[-–]\s*\d+)?\s+(words|tags)$"#, options: .regularExpression) != nil }
        var joined = tags.joined(separator: ", ")
        while joined.hasSuffix(".") { joined.removeLast() }
        for prefix in [PromptInstructions.ponyPrefix, PromptInstructions.booruPrefix] where joined.hasPrefix(prefix) {
            let rest = joined.dropFirst(prefix.count)
            if let next = rest.first, next != "," { joined = prefix + ", " + rest.trimmingCharacters(in: .whitespaces) }
        }
        return joined
    }

    /// Removes `<think>…</think>`; an unterminated block (still streaming) hides everything after it.
    static func stripThinking(_ raw: String) -> String {
        var text = raw
        while let open = text.range(of: "<think>") {
            if let close = text.range(of: "</think>", range: open.upperBound..<text.endIndex) {
                text.removeSubrange(open.lowerBound..<close.upperBound)
            } else {
                text.removeSubrange(open.lowerBound..<text.endIndex)
            }
        }
        return text
    }

    /// Tag-based models degrade badly without their quality prefix; guarantee it.
    static func ensurePrefix(_ text: String, style: PromptStyle) -> String {
        let prefix: String
        switch style {
        case .ponyTags: prefix = PromptInstructions.ponyPrefix
        case .booruTags: prefix = PromptInstructions.booruPrefix
        case .naturalLanguage, .sdxlPhrases: return text
        }
        if text.isEmpty || text.lowercased().hasPrefix(prefix) { return text }
        return "\(prefix), \(text)"
    }
}
