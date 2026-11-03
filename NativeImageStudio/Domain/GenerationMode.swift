import Foundation

/// What the engine is asked to do. Independent of any inference backend.
public enum GenerationMode: Sendable, Hashable, Codable {
    /// Prompt only, no input images.
    case textToImage
    /// One primary image transformed by the prompt. `strength` in (0, 1]:
    /// how far the result may move away from the original.
    case imageToImage(strength: Float)
    /// 1...N reference images + instruction prompt → one new image.
    case referenceEdit
    /// Primary image + mask (white = repaint) + prompt.
    case inpainting(mask: InputImage)

    public var kind: ModeKind {
        switch self {
        case .textToImage: .textToImage
        case .imageToImage: .imageToImage
        case .referenceEdit: .referenceEdit
        case .inpainting: .inpainting
        }
    }
}

/// Payload-free discriminator of `GenerationMode`, used in capabilities and manifests.
public enum ModeKind: String, Sendable, Hashable, Codable, CaseIterable, Comparable {
    case textToImage
    case imageToImage
    case referenceEdit
    case inpainting

    public static func < (lhs: ModeKind, rhs: ModeKind) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }

    /// Whether the mode consumes input images.
    public var usesInputImages: Bool { self != .textToImage }
}
