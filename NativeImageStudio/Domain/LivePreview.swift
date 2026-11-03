import Foundation

/// What the engine shows of an image while it is being denoised.
public enum LivePreviewMode: String, Sendable, Codable, CaseIterable {
    case off
    /// Latents mapped to RGB by a fitted linear map: blurry, near-zero cost, every step.
    case approximate
    /// Real VAE decode of the intermediate latents every few steps (FLUX.2, SDXL); costs time and memory.
    case fullDecode
}

/// Small 8-bit RGBA image of an image in progress (alpha always 255).
public struct PreviewFrame: Sendable, Hashable {
    public let step: Int
    public let totalSteps: Int
    public let width: Int
    public let height: Int
    public let rgba: Data
    /// Linear latent→RGB estimate rather than a VAE decode.
    public let isApproximate: Bool

    public init(step: Int, totalSteps: Int, width: Int, height: Int, rgba: Data, isApproximate: Bool) {
        precondition(rgba.count == width * height * 4, "RGBA buffer does not match the size")
        self.step = step
        self.totalSteps = totalSteps
        self.width = width
        self.height = height
        self.rgba = rgba
        self.isApproximate = isApproximate
    }
}
