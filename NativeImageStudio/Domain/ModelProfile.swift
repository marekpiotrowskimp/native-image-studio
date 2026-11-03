import Foundation

/// Saved set of settings, adapters and workflow for a model ("Model Profile").
/// Replaces ad-hoc toggles: a profile only stores parameters the model declares support for.
public struct ModelProfile: Sendable, Hashable, Codable, Identifiable {
    public enum Workflow: String, Sendable, Hashable, Codable, CaseIterable {
        case textToImage, transform, references, batch, inpainting
    }

    public var id: UUID
    public var name: String
    public var modelID: String
    public var workflow: Workflow
    public var steps: Int
    public var guidance: Float
    public var resolution: Int
    public var strength: Float?
    public var negativePrompt: String?
    public var promptPrefix: String?
    public var resizeMode: ResizeMode
    public var loras: [LoRAReference]
    public var notes: String?

    public init(
        id: UUID = UUID(), name: String, modelID: String, workflow: Workflow,
        steps: Int, guidance: Float, resolution: Int, strength: Float? = nil,
        negativePrompt: String? = nil, promptPrefix: String? = nil,
        resizeMode: ResizeMode = .crop, loras: [LoRAReference] = [], notes: String? = nil
    ) {
        self.id = id
        self.name = name
        self.modelID = modelID
        self.workflow = workflow
        self.steps = steps
        self.guidance = guidance
        self.resolution = resolution
        self.strength = strength
        self.negativePrompt = negativePrompt
        self.promptPrefix = promptPrefix
        self.resizeMode = resizeMode
        self.loras = loras
        self.notes = notes
    }

    /// Problems that make the profile unusable with the given capabilities (empty = OK).
    public func incompatibilities(with caps: EngineCapabilities) -> [String] {
        var issues: [String] = []
        let needed: ModeKind = switch workflow {
        case .textToImage: .textToImage
        case .transform: .imageToImage
        case .references: .referenceEdit
        case .batch: caps.supports(.imageToImage) ? .imageToImage : .referenceEdit
        case .inpainting: .inpainting
        }
        if !caps.supports(needed) { issues.append("Model nie obsługuje trybu \(needed.rawValue).") }
        if !loras.isEmpty && !caps.supportsLoRA { issues.append("Model nie obsługuje LoRA.") }
        if let n = negativePrompt, !n.isEmpty, !caps.supportsNegativePrompt { issues.append("Model nie obsługuje negatywnego promptu.") }
        if steps > caps.maxSteps { issues.append("Za dużo kroków (\(steps) > \(caps.maxSteps)).") }
        if steps < caps.minSteps { issues.append("Za mało kroków (\(steps) < \(caps.minSteps)).") }
        if resolution < caps.minDimension || resolution > caps.maxDimension {
            issues.append("Rozdzielczość \(resolution) poza zakresem \(caps.minDimension)–\(caps.maxDimension).")
        }
        return issues
    }
}
