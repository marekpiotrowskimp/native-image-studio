import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Generates small synthetic test images (no third-party or private photos).
public enum FixtureFactory {
    /// Quadrant colors of `quadrantImage`, top-left, top-right, bottom-left, bottom-right (RGB 0–255).
    public static let quadrantColors: [(UInt8, UInt8, UInt8)] = [
        (255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 255, 0),
    ]

    public static func temporaryDirectory(_ name: String = #function) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NISTests-\(name.filter(\.isLetter))-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Four solid quadrants (TL red, TR green, BL blue, BR yellow) as stored in pixels.
    public static func quadrantImage(width: Int, height: Int, colorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!) -> CGImage {
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // CoreGraphics origin is bottom-left.
        let halfW = CGFloat(width) / 2, halfH = CGFloat(height) / 2
        let rects: [CGRect] = [
            CGRect(x: 0, y: halfH, width: halfW, height: halfH),
            CGRect(x: halfW, y: halfH, width: halfW, height: halfH),
            CGRect(x: 0, y: 0, width: halfW, height: halfH),
            CGRect(x: halfW, y: 0, width: halfW, height: halfH),
        ]
        for (rect, c) in zip(rects, quadrantColors) {
            ctx.setFillColor(CGColor(colorSpace: colorSpace, components: [CGFloat(c.0) / 255, CGFloat(c.1) / 255, CGFloat(c.2) / 255, 1])!)
            ctx.fill(rect)
        }
        return ctx.makeImage()!
    }

    public static func solidImage(width: Int, height: Int, rgb: (CGFloat, CGFloat, CGFloat), colorSpace: CGColorSpace) -> CGImage {
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(colorSpace: colorSpace, components: [rgb.0, rgb.1, rgb.2, 1])!)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    /// Writes `image` with an optional EXIF orientation tag (1–8).
    @discardableResult
    public static func write(_ image: CGImage, to url: URL, type: UTType, orientation: Int? = nil) throws -> URL {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        var props: [CFString: Any] = [:]
        if let orientation { props[kCGImagePropertyOrientation] = orientation }
        if type == .jpeg || type == .heic { props[kCGImageDestinationLossyCompressionQuality] = 1.0 }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
        return url
    }

    /// RGBA8 sRGB pixel at (x, y) with origin top-left.
    public static func pixel(_ image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        var data = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(
            data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // Draw so that pixel (x, y) [top-left origin] lands on the single context pixel.
        ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (Int(data[0]), Int(data[1]), Int(data[2]))
    }

    /// Bundled fixture directory (Tests/TestSupport/Fixtures).
    public static var bundledFixtures: URL {
        Bundle.module.url(forResource: "Fixtures", withExtension: nil)!
    }
}
