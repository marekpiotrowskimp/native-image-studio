import CoreGraphics
import CryptoKit
import Domain
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImageInputError: Error, Sendable, Equatable, LocalizedError {
    case cannotOpen(URL)
    case cannotDecode(URL)
    case unsupportedFormat(URL, String)
    case renderFailed

    public var errorDescription: String? {
        switch self {
        case .cannotOpen(let url): "Nie można otworzyć pliku \(url.lastPathComponent)."
        case .cannotDecode(let url): "Nie można zdekodować obrazu \(url.lastPathComponent)."
        case .unsupportedFormat(let url, let type): "Nieobsługiwany format \(type) (\(url.lastPathComponent)). Obsługiwane: JPEG, PNG, HEIC, TIFF."
        case .renderFailed: "Nie udało się przeskalować obrazu."
        }
    }
}

/// Pixel dimensions after applying EXIF orientation.
public struct PixelSize: Sendable, Hashable, Codable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public var aspectRatio: Double { Double(width) / Double(height) }
    public var megapixels: Double { Double(width * height) / 1_000_000 }
}

/// Decodes user images (JPEG/PNG/HEIC/TIFF), applies EXIF orientation, converts to
/// 8-bit sRGB and maps them onto the model's resolution grid. Pure CPU work: call it
/// off the main actor.
public struct ImageInputProcessor: Sendable {
    public static let supportedTypes: [UTType] = [.jpeg, .png, .heic, .heif, .tiff]

    public static let sRGB: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    public init() {}

    // MARK: Inspection

    public func uniformType(of url: URL) throws -> UTType {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ImageInputError.cannotOpen(url)
        }
        guard let identifier = CGImageSourceGetType(source) as String?,
              let type = UTType(identifier) else {
            throw ImageInputError.cannotDecode(url)
        }
        return type
    }

    /// Size as displayed (EXIF orientation 5–8 swaps width and height).
    public func orientedSize(of url: URL) throws -> PixelSize {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ImageInputError.cannotOpen(url)
        }
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else {
            throw ImageInputError.cannotDecode(url)
        }
        let orientation = (props[kCGImagePropertyOrientation] as? UInt32) ?? 1
        return (5...8).contains(orientation) ? PixelSize(width: h, height: w) : PixelSize(width: w, height: h)
    }

    // MARK: Decoding

    /// Full-resolution image, upright (EXIF applied), 8-bit RGBA in sRGB.
    public func loadNormalized(_ url: URL) throws -> CGImage {
        let type = try uniformType(of: url)
        guard Self.supportedTypes.contains(where: { type.conforms(to: $0) }) else {
            throw ImageInputError.unsupportedFormat(url, type.preferredFilenameExtension ?? type.identifier)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ImageInputError.cannotOpen(url)
        }
        let size = try orientedSize(of: url)
        // The thumbnail API is the ImageIO-supported way to bake in EXIF orientation;
        // with max size = longest edge it returns full resolution.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(size.width, size.height),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let oriented = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ImageInputError.cannotDecode(url)
        }
        return try render(oriented, into: PixelSize(width: oriented.width, height: oriented.height),
                          drawRect: CGRect(x: 0, y: 0, width: oriented.width, height: oriented.height),
                          background: nil)
    }

    // MARK: Geometry

    /// Output size with the given aspect ratio and ~`targetEdge²` pixels, snapped to `multiple`
    /// and clamped to `[minDimension, maxDimension]`.
    public static func targetSize(
        aspectRatio: Double,
        targetEdge: Int,
        multiple: Int,
        minDimension: Int = 256,
        maxDimension: Int = 2048
    ) -> PixelSize {
        let ratio = aspectRatio.isFinite && aspectRatio > 0 ? aspectRatio : 1
        let area = Double(targetEdge * targetEdge)
        let rawW = (area * ratio).squareRoot()
        let rawH = (area / ratio).squareRoot()
        func snap(_ v: Double) -> Int {
            let m = Double(max(1, multiple))
            let snapped = Int((v / m).rounded()) * Int(m)
            let lo = Int((Double(minDimension) / m).rounded(.up)) * Int(m)
            let hi = Int((Double(maxDimension) / m).rounded(.down)) * Int(m)
            return min(max(snapped, lo), hi)
        }
        return PixelSize(width: snap(rawW), height: snap(rawH))
    }

    /// Where the source lands on a `target` canvas for the given mode.
    public static func drawRect(source: PixelSize, target: PixelSize, mode: ResizeMode) -> CGRect {
        let sw = Double(source.width), sh = Double(source.height)
        let tw = Double(target.width), th = Double(target.height)
        switch mode {
        case .fit:
            // Target already follows the source aspect (see targetSize); stretch the
            // sub-`multiple` remainder instead of padding or cropping.
            return CGRect(x: 0, y: 0, width: tw, height: th)
        case .crop:
            let scale = max(tw / sw, th / sh)
            let w = sw * scale, h = sh * scale
            return CGRect(x: (tw - w) / 2, y: (th - h) / 2, width: w, height: h)
        case .pad:
            let scale = min(tw / sw, th / sh)
            let w = sw * scale, h = sh * scale
            return CGRect(x: (tw - w) / 2, y: (th - h) / 2, width: w, height: h)
        }
    }

    // MARK: Resampling

    public func resize(_ image: CGImage, to target: PixelSize, mode: ResizeMode) throws -> CGImage {
        let source = PixelSize(width: image.width, height: image.height)
        if source == target { return image }
        let rect = Self.drawRect(source: source, target: target, mode: mode)
        return try render(image, into: target, drawRect: rect, background: mode == .pad ? .black : nil)
    }

    /// Load, orient, convert to sRGB and resize in one go.
    public func prepare(_ url: URL, target: PixelSize, mode: ResizeMode) throws -> CGImage {
        try resize(loadNormalized(url), to: target, mode: mode)
    }

    private func render(_ image: CGImage, into size: PixelSize, drawRect: CGRect, background: CGColor?) throws -> CGImage {
        guard let ctx = CGContext(
            data: nil,
            width: size.width,
            height: size.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: Self.sRGB,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw ImageInputError.renderFailed }
        ctx.interpolationQuality = .high
        if let background {
            ctx.setFillColor(background)
            ctx.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height))
        }
        // Drawing into an sRGB context performs the ColorSync conversion from the
        // source profile (Display P3, Adobe RGB, …).
        ctx.draw(image, in: drawRect)
        guard let out = ctx.makeImage() else { throw ImageInputError.renderFailed }
        return out
    }

    // MARK: Hashing

    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
