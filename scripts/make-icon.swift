// Draws the app icon (vector, CoreGraphics) into an .iconset directory.
// Usage: swift scripts/make-icon.swift <out.iconset>   (then: iconutil -c icns <out.iconset>)
// Design: macOS icon grid (824 pt body on a 1024 canvas), indigo → coral gradient, a tilted photo
// with a landscape and a sparkle for "generated".
import AppKit
import CoreGraphics

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: locations)!
}

/// Four-pointed star with concave sides.
func sparkle(center c: CGPoint, radius r: CGFloat) -> CGPath {
    let p = CGMutablePath()
    let k = r * 0.16
    p.move(to: CGPoint(x: c.x, y: c.y + r))
    p.addQuadCurve(to: CGPoint(x: c.x + r, y: c.y), control: CGPoint(x: c.x + k, y: c.y + k))
    p.addQuadCurve(to: CGPoint(x: c.x, y: c.y - r), control: CGPoint(x: c.x + k, y: c.y - k))
    p.addQuadCurve(to: CGPoint(x: c.x - r, y: c.y), control: CGPoint(x: c.x - k, y: c.y - k))
    p.addQuadCurve(to: CGPoint(x: c.x, y: c.y + r), control: CGPoint(x: c.x - k, y: c.y + k))
    p.closeSubpath()
    return p
}

func draw(_ ctx: CGContext) {
    // Body with drop shadow.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x000000, 0.35))
    ctx.addPath(bodyPath)
    ctx.setFillColor(color(0x2B2A86))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    ctx.drawLinearGradient(gradient([color(0x23257A), color(0x7A3BC4), color(0xFF7A5C)], [0, 0.55, 1]),
                           start: CGPoint(x: 160, y: 924), end: CGPoint(x: 880, y: 100), options: [])
    // Soft light from the top.
    ctx.drawRadialGradient(gradient([color(0xFFFFFF, 0.22), color(0xFFFFFF, 0)], [0, 1]),
                           startCenter: CGPoint(x: 420, y: 900), startRadius: 0,
                           endCenter: CGPoint(x: 420, y: 900), endRadius: 560, options: [])

    // Tilted photo card.
    ctx.saveGState()
    ctx.translateBy(x: 470, y: 450)
    ctx.rotate(by: -8 * .pi / 180)
    let card = CGRect(x: -250, y: -205, width: 500, height: 410)
    let cardPath = CGPath(roundedRect: card, cornerWidth: 42, cornerHeight: 42, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 40, color: color(0x10082E, 0.55))
    ctx.addPath(cardPath)
    ctx.setFillColor(color(0xFFFFFF))
    ctx.fillPath()
    ctx.restoreGState()

    let photo = card.insetBy(dx: 26, dy: 26)
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: photo, cornerWidth: 22, cornerHeight: 22, transform: nil))
    ctx.clip()
    ctx.drawLinearGradient(gradient([color(0x5B7CFA), color(0xC58BF2), color(0xFFB38A)], [0, 0.55, 1]),
                           start: CGPoint(x: 0, y: photo.maxY), end: CGPoint(x: 0, y: photo.minY), options: [])
    // Sun.
    ctx.setFillColor(color(0xFFF1C9))
    ctx.fillEllipse(in: CGRect(x: 40, y: 10, width: 120, height: 120))
    // Mountains: far, then near.
    let far = CGMutablePath()
    far.move(to: CGPoint(x: photo.minX, y: -60))
    far.addLine(to: CGPoint(x: -110, y: 70))
    far.addLine(to: CGPoint(x: 0, y: -20))
    far.addLine(to: CGPoint(x: 110, y: 40))
    far.addLine(to: CGPoint(x: photo.maxX, y: -90))
    far.addLine(to: CGPoint(x: photo.maxX, y: photo.minY))
    far.addLine(to: CGPoint(x: photo.minX, y: photo.minY))
    far.closeSubpath()
    ctx.addPath(far)
    ctx.setFillColor(color(0x6A4FB8))
    ctx.fillPath()
    let near = CGMutablePath()
    near.move(to: CGPoint(x: photo.minX, y: -120))
    near.addLine(to: CGPoint(x: -60, y: -10))
    near.addLine(to: CGPoint(x: 60, y: -110))
    near.addLine(to: CGPoint(x: 150, y: -50))
    near.addLine(to: CGPoint(x: photo.maxX, y: -150))
    near.addLine(to: CGPoint(x: photo.maxX, y: photo.minY))
    near.addLine(to: CGPoint(x: photo.minX, y: photo.minY))
    near.closeSubpath()
    ctx.addPath(near)
    ctx.setFillColor(color(0x2C2370))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.restoreGState()

    // Sparkles with glow.
    for (center, radius) in [(CGPoint(x: 712, y: 712), CGFloat(150)), (CGPoint(x: 820, y: 540), CGFloat(56)),
                             (CGPoint(x: 590, y: 820), CGFloat(40))] {
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: radius * 0.45, color: color(0xFFE7B0, 0.9))
        ctx.addPath(sparkle(center: center, radius: radius))
        ctx.setFillColor(color(0xFFFFFF))
        ctx.fillPath()
        ctx.restoreGState()
    }
    ctx.restoreGState()
}

func render(pixels: Int) -> Data {
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    draw(ctx)
    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try render(pixels: points * scale).write(to: out.appendingPathComponent(name))
    }
}
