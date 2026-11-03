import CoreGraphics
import Foundation
import ImageIO

/// Geometry of an aspect-fit image inside a container (shared by the mask editor and
/// the before/after comparison so overlays line up with the pixels).
public enum FitGeometry {
    /// Rect occupied by an image of `aspect` (w/h) scaled to fit and centered in `size`.
    public static func fittedRect(aspect: CGFloat, in size: CGSize) -> CGRect {
        guard aspect > 0, size.width > 0, size.height > 0 else { return CGRect(origin: .zero, size: size) }
        if size.width / size.height > aspect {
            let w = size.height * aspect
            return CGRect(x: (size.width - w) / 2, y: 0, width: w, height: size.height)
        }
        let h = size.width / aspect
        return CGRect(x: 0, y: (size.height - h) / 2, width: size.width, height: h)
    }

    /// Horizontal position inside `rect` as a 0…1 fraction (clamped).
    public static func fraction(ofX x: CGFloat, in rect: CGRect) -> CGFloat {
        guard rect.width > 0 else { return 0 }
        return min(1, max(0, (x - rect.minX) / rect.width))
    }

    /// Displayed aspect ratio of an image file (EXIF orientation applied), header read only.
    public static func aspectRatio(of url: URL) -> CGFloat? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0 else { return nil }
        let o = (p[kCGImagePropertyOrientation] as? UInt32) ?? 1
        return (5...8).contains(o) ? CGFloat(h) / CGFloat(w) : CGFloat(w) / CGFloat(h)
    }
}
