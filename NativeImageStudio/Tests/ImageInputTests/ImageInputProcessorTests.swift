import CoreGraphics
import Domain
import Foundation
import Infrastructure
import TestSupport
import Testing
import UniformTypeIdentifiers

/// Color within tolerance (lossy codecs, resampling at edges).
func close(_ p: (r: Int, g: Int, b: Int), _ c: (UInt8, UInt8, UInt8), tol: Int = 12) -> Bool {
    abs(p.r - Int(c.0)) <= tol && abs(p.g - Int(c.1)) <= tol && abs(p.b - Int(c.2)) <= tol
}

@Suite("Image input processing")
struct ImageInputProcessorTests {
    let processor = ImageInputProcessor()
    let red = FixtureFactory.quadrantColors[0]
    let green = FixtureFactory.quadrantColors[1]
    let blue = FixtureFactory.quadrantColors[2]
    let yellow = FixtureFactory.quadrantColors[3]

    // MARK: Formats

    @Test(arguments: [UTType.jpeg, .png, .heic, .tiff])
    func decodesSupportedFormats(type: UTType) throws {
        let dir = try FixtureFactory.temporaryDirectory()
        let url = try FixtureFactory.write(
            FixtureFactory.quadrantImage(width: 64, height: 48),
            to: dir.appendingPathComponent("img.\(type.preferredFilenameExtension!)"), type: type)
        let image = try processor.loadNormalized(url)
        #expect(image.width == 64 && image.height == 48)
        #expect(image.bitsPerComponent == 8)
        #expect(image.colorSpace?.name == CGColorSpace.sRGB)
        #expect(close(FixtureFactory.pixel(image, x: 8, y: 8), red))
        #expect(close(FixtureFactory.pixel(image, x: 56, y: 40), yellow))
    }

    @Test func rejectsUnsupportedFormat() throws {
        let dir = try FixtureFactory.temporaryDirectory()
        let url = try FixtureFactory.write(FixtureFactory.quadrantImage(width: 16, height: 16),
                                           to: dir.appendingPathComponent("img.gif"), type: .gif)
        #expect(throws: ImageInputError.self) { try processor.loadNormalized(url) }
    }

    @Test func rejectsNonImage() throws {
        let dir = try FixtureFactory.temporaryDirectory()
        let url = dir.appendingPathComponent("text.png")
        try Data("not an image".utf8).write(to: url)
        #expect(throws: ImageInputError.self) { try processor.loadNormalized(url) }
    }

    // MARK: EXIF orientation

    /// Stored pixels: TL red, TR green, BL blue, BR yellow. Expected *displayed* corners per tag.
    @Test(arguments: [
        (1, 0, 1, 2, 3),  // up
        (3, 3, 2, 1, 0),  // rotated 180°
        (6, 2, 0, 3, 1),  // rotate 90° CW to display
        (8, 1, 3, 0, 2),  // rotate 90° CCW to display
        (2, 1, 0, 3, 2),  // mirrored horizontally
    ])
    func appliesExifOrientation(tag: Int, tl: Int, tr: Int, bl: Int, br: Int) throws {
        let dir = try FixtureFactory.temporaryDirectory()
        let url = try FixtureFactory.write(
            FixtureFactory.quadrantImage(width: 80, height: 40),
            to: dir.appendingPathComponent("o\(tag).jpg"), type: .jpeg, orientation: tag)

        let size = try processor.orientedSize(of: url)
        let swapped = (5...8).contains(tag)
        #expect(size == (swapped ? PixelSize(width: 40, height: 80) : PixelSize(width: 80, height: 40)))

        let image = try processor.loadNormalized(url)
        #expect(image.width == size.width && image.height == size.height)
        let colors = FixtureFactory.quadrantColors
        let w = image.width, h = image.height
        #expect(close(FixtureFactory.pixel(image, x: w / 8, y: h / 8), colors[tl]))
        #expect(close(FixtureFactory.pixel(image, x: w - 1 - w / 8, y: h / 8), colors[tr]))
        #expect(close(FixtureFactory.pixel(image, x: w / 8, y: h - 1 - h / 8), colors[bl]))
        #expect(close(FixtureFactory.pixel(image, x: w - 1 - w / 8, y: h - 1 - h / 8), colors[br]))
    }

    // MARK: Color

    @Test func convertsDisplayP3ToSRGB() throws {
        let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
        let dir = try FixtureFactory.temporaryDirectory()
        // Pure P3 red is outside sRGB; the converted value must be clipped/mapped, and a
        // mid-gray must stay gray.
        let redURL = try FixtureFactory.write(FixtureFactory.solidImage(width: 8, height: 8, rgb: (1, 0, 0), colorSpace: p3),
                                              to: dir.appendingPathComponent("p3red.png"), type: .png)
        let grayURL = try FixtureFactory.write(FixtureFactory.solidImage(width: 8, height: 8, rgb: (0.5, 0.5, 0.5), colorSpace: p3),
                                               to: dir.appendingPathComponent("p3gray.png"), type: .png)
        let red = try processor.loadNormalized(redURL)
        #expect(red.colorSpace?.name == CGColorSpace.sRGB)
        let r = FixtureFactory.pixel(red, x: 4, y: 4)
        #expect(r.r >= 250 && r.g <= 10 && r.b <= 10)

        // A P3 color inside the sRGB gamut must change its numeric values (proof that a
        // conversion happened, not a reinterpretation).
        let mid = try FixtureFactory.write(FixtureFactory.solidImage(width: 8, height: 8, rgb: (0.6, 0.4, 0.3), colorSpace: p3),
                                           to: dir.appendingPathComponent("p3mid.png"), type: .png)
        let m = FixtureFactory.pixel(try processor.loadNormalized(mid), x: 4, y: 4)
        #expect(m.r > 153 + 3)  // sRGB red component of a P3 orange is larger than 0.6·255

        let g = FixtureFactory.pixel(try processor.loadNormalized(grayURL), x: 4, y: 4)
        #expect(abs(g.r - g.g) <= 2 && abs(g.g - g.b) <= 2)
    }

    // MARK: Geometry

    @Test func targetSizeKeepsAspectAndMultiple() {
        let s = ImageInputProcessor.targetSize(aspectRatio: 3.0 / 2.0, targetEdge: 1024, multiple: 32)
        #expect(s.width % 32 == 0 && s.height % 32 == 0)
        #expect(abs(s.aspectRatio - 1.5) < 0.05)
        // Pixel budget stays close to 1024².
        #expect(abs(Double(s.width * s.height) / Double(1024 * 1024) - 1) < 0.06)

        let square = ImageInputProcessor.targetSize(aspectRatio: 1, targetEdge: 1024, multiple: 32)
        #expect(square == PixelSize(width: 1024, height: 1024))

        let portrait = ImageInputProcessor.targetSize(aspectRatio: 9.0 / 16.0, targetEdge: 768, multiple: 16)
        #expect(portrait.width < portrait.height)
        #expect(portrait.width % 16 == 0 && portrait.height % 16 == 0)
    }

    @Test func targetSizeClampsExtremeAspect() {
        let s = ImageInputProcessor.targetSize(aspectRatio: 20, targetEdge: 1024, multiple: 32, minDimension: 256, maxDimension: 2048)
        #expect(s.width == 2048)
        #expect(s.height == 256)
        let invalid = ImageInputProcessor.targetSize(aspectRatio: .nan, targetEdge: 512, multiple: 32)
        #expect(invalid == PixelSize(width: 512, height: 512))
    }

    @Test func cropFillsAndCentersOverflow() throws {
        // 200×100 into 100×100: crop keeps the central square → left half red/blue
        // at x=0 is cut, center column is the boundary between quadrants.
        let src = FixtureFactory.quadrantImage(width: 200, height: 100)
        let out = try processor.resize(src, to: PixelSize(width: 100, height: 100), mode: .crop)
        #expect(out.width == 100 && out.height == 100)
        #expect(close(FixtureFactory.pixel(out, x: 10, y: 10), red))
        #expect(close(FixtureFactory.pixel(out, x: 90, y: 90), yellow))
        let rect = ImageInputProcessor.drawRect(source: PixelSize(width: 200, height: 100), target: PixelSize(width: 100, height: 100), mode: .crop)
        #expect(rect == CGRect(x: -50, y: 0, width: 200, height: 100))
    }

    @Test func padLetterboxesWithBlack() throws {
        let src = FixtureFactory.quadrantImage(width: 200, height: 100)
        let out = try processor.resize(src, to: PixelSize(width: 100, height: 100), mode: .pad)
        #expect(out.width == 100 && out.height == 100)
        // Top and bottom bars (25 px each) are black.
        #expect(close(FixtureFactory.pixel(out, x: 50, y: 5), (0, 0, 0)))
        #expect(close(FixtureFactory.pixel(out, x: 50, y: 95), (0, 0, 0)))
        #expect(close(FixtureFactory.pixel(out, x: 10, y: 30), red))
        #expect(close(FixtureFactory.pixel(out, x: 90, y: 70), yellow))
    }

    @Test func fitStretchesToExactTarget() throws {
        let src = FixtureFactory.quadrantImage(width: 300, height: 200)
        let out = try processor.resize(src, to: PixelSize(width: 96, height: 64), mode: .fit)
        #expect(out.width == 96 && out.height == 64)
        #expect(close(FixtureFactory.pixel(out, x: 5, y: 5), red))
        #expect(close(FixtureFactory.pixel(out, x: 90, y: 5), green))
        #expect(close(FixtureFactory.pixel(out, x: 5, y: 60), blue))
    }

    @Test func prepareCombinesOrientationAndResize() throws {
        let dir = try FixtureFactory.temporaryDirectory()
        let url = try FixtureFactory.write(FixtureFactory.quadrantImage(width: 120, height: 60),
                                           to: dir.appendingPathComponent("p.jpg"), type: .jpeg, orientation: 6)
        let size = try processor.orientedSize(of: url)
        let target = ImageInputProcessor.targetSize(aspectRatio: size.aspectRatio, targetEdge: 64, multiple: 16, minDimension: 16)
        let out = try processor.prepare(url, target: target, mode: .crop)
        #expect(out.width == target.width && out.height == target.height)
        #expect(out.height > out.width)  // portrait after EXIF rotation
    }

    // MARK: Hash & non-destructive

    @Test func hashIsStableAndOriginalUntouched() throws {
        let dir = try FixtureFactory.temporaryDirectory()
        let url = try FixtureFactory.write(FixtureFactory.quadrantImage(width: 32, height: 32),
                                           to: dir.appendingPathComponent("h.png"), type: .png)
        let before = try Data(contentsOf: url)
        let h1 = try ImageInputProcessor.sha256(of: url)
        _ = try processor.prepare(url, target: PixelSize(width: 16, height: 16), mode: .crop)
        let h2 = try ImageInputProcessor.sha256(of: url)
        #expect(h1 == h2)
        #expect(h1.count == 64)
        #expect(try Data(contentsOf: url) == before)
    }
}
