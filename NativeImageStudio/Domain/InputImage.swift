import Foundation

/// A user-provided image file. The original file is never modified.
public struct InputImage: Sendable, Hashable, Codable {
    public enum Role: String, Sendable, Hashable, Codable {
        /// The image being transformed / edited.
        case primary
        /// Additional visual context for reference edits.
        case reference
        /// Inpainting mask (white = area to regenerate).
        case mask
    }

    public let sourceURL: URL
    public let role: Role

    public init(sourceURL: URL, role: Role) {
        self.sourceURL = sourceURL
        self.role = role
    }
}

/// How an input image is mapped onto the model's required resolution.
public enum ResizeMode: String, Sendable, Hashable, Codable, CaseIterable {
    /// Scale to fit inside the target; may leave the target smaller on one axis
    /// (the target size is derived from the aspect ratio, so usually exact).
    case fit
    /// Scale to fill and center-crop the overflow.
    case crop
    /// Scale to fit and pad the remaining area.
    case pad
}
