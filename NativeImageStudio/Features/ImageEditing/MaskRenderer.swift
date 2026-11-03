import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// One brush stroke in normalized image coordinates (0…1, origin top-left).
public struct MaskStroke: Sendable, Equatable {
    public var points: [CGPoint]
    /// Brush diameter as a fraction of the image's shorter edge.
    public var width: CGFloat
    /// `true` paints "keep" (black) over previously painted area.
    public var erase: Bool

    public init(points: [CGPoint], width: CGFloat, erase: Bool) {
        self.points = points
        self.width = width
        self.erase = erase
    }
}

/// Rasterizes strokes into an inpainting mask: white = regenerate, black = keep
/// (the convention `Flux2MaskedInpaintingChain` expects), soft edge via blur-free round caps.
public enum MaskRenderer {
    public static func render(_ strokes: [MaskStroke], width: Int, height: Int, inverted: Bool = false) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        let keep: CGFloat = inverted ? 1 : 0
        ctx.setFillColor(gray: keep, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // Flip to top-left origin to match normalized view coordinates.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        let shorter = CGFloat(min(width, height))
        for stroke in strokes where !stroke.points.isEmpty {
            let paint: CGFloat = stroke.erase ? keep : 1 - keep
            ctx.setStrokeColor(gray: paint, alpha: 1)
            ctx.setFillColor(gray: paint, alpha: 1)
            let w = max(1, stroke.width * shorter)
            ctx.setLineWidth(w)
            let pts = stroke.points.map { CGPoint(x: $0.x * CGFloat(width), y: $0.y * CGFloat(height)) }
            if pts.count == 1 {
                ctx.fillEllipse(in: CGRect(x: pts[0].x - w / 2, y: pts[0].y - w / 2, width: w, height: w))
            } else {
                ctx.addLines(between: pts)
                ctx.strokePath()
            }
        }
        return ctx.makeImage()
    }

    /// Fraction of pixels marked for regeneration (UI hint, validation).
    public static func coverage(_ mask: CGImage) -> Double {
        let w = mask.width, h = mask.height
        var data = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return 0 }
        ctx.draw(mask, in: CGRect(x: 0, y: 0, width: w, height: h))
        return Double(data.filter { $0 > 127 }.count) / Double(max(1, w * h))
    }

    /// Writes the mask as a new PNG (never overwrites).
    public static func write(_ mask: CGImage, in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("mask-\(UUID().uuidString.prefix(8)).png")
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(dest, mask, nil)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
        return url
    }

    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NativeImageStudio/Masks", isDirectory: true)
    }
}
