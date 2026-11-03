import AppKit
import CoreGraphics
import Foundation
import ImageIO
import SwiftUI

/// CGImage is immutable; this box lets it cross isolation boundaries explicitly.
public struct SendableImage: @unchecked Sendable {
    public let cgImage: CGImage
    public init(_ cgImage: CGImage) { self.cgImage = cgImage }
}

/// Decodes downscaled, EXIF-oriented thumbnails off the main actor, with an in-memory cache.
public actor ThumbnailCache {
    public static let shared = ThumbnailCache()
    private var cache: [String: SendableImage] = [:]

    public func thumbnail(for url: URL, maxPixel: Int = 320) -> SendableImage? {
        let key = "\(url.path)#\(maxPixel)"
        if let hit = cache[key] { return hit }
        guard let image = Self.decode(url, maxPixel: maxPixel) else { return nil }
        let boxed = SendableImage(image)
        if cache.count > 500 { cache.removeAll() }
        cache[key] = boxed
        return boxed
    }

    public func invalidate(_ url: URL) {
        cache = cache.filter { !$0.key.hasPrefix(url.path + "#") }
    }

    nonisolated static func decode(_ url: URL, maxPixel: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }
}

/// Async thumbnail view for a file URL.
public struct ThumbnailView: View {
    let url: URL
    let maxPixel: Int
    var contentMode: ContentMode = .fill
    @State private var image: SendableImage?

    public init(url: URL, maxPixel: Int = 320, contentMode: ContentMode = .fill) {
        self.url = url
        self.maxPixel = maxPixel
        self.contentMode = contentMode
    }

    public var body: some View {
        ZStack {
            if let image {
                Image(decorative: image.cgImage, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                Rectangle().fill(.quaternary)
                ProgressView().controlSize(.small)
            }
        }
        .task(id: "\(url.path)#\(maxPixel)") {
            image = await ThumbnailCache.shared.thumbnail(for: url, maxPixel: maxPixel)
        }
    }
}
