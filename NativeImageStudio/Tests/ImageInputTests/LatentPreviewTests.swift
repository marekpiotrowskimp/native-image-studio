import CoreGraphics
import Domain
import Foundation
import Infrastructure
import Testing

@Suite("Live preview: latent → RGB")
struct LatentPreviewTests {
    /// Deterministic pseudo-random values in -1…1.
    func noise(_ count: Int, seed: UInt64) -> [Float] {
        var state = seed
        return (0..<count).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int64(bitPattern: state >> 11) % 2000) / 1000 - 1
        }
    }

    func image(_ frame: PreviewFrame) -> CGImage {
        let provider = CGDataProvider(data: frame.rgba as CFData)!
        return CGImage(width: frame.width, height: frame.height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: frame.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    @Test(arguments: [1, 2])
    func fitRecoversAKnownLinearMap(block: Int) throws {
        let channels = 4
        let outputs = 3 * block * block
        // Small weights + mid-grey bias keep every output inside 0…1 (no clipping).
        let truth = LatentRGBFactors(
            family: "test", channels: channels, block: block,
            weights: noise(channels * outputs, seed: 7).map { $0 * 0.1 } + [Float](repeating: 0.5, count: outputs),
            note: "")
        var fitter = LatentRGBFitter(channels: channels, block: block)
        var heldOut: (LatentGrid, [Double])?
        for seed in UInt64(1)...4 {
            let grid = LatentGrid(step: 1, totalSteps: 1, gridWidth: 16, gridHeight: 12, channels: channels,
                                  values: noise(16 * 12 * channels, seed: seed))
            let frame = try #require(LatentPreview.frame(grid, factors: truth, smooth: false))
            #expect(frame.width == 16 * block && frame.height == 12 * block)
            let targets = try #require(LatentRGBFitter.targets(image(frame), grid: grid, block: block))
            if seed == 4 { heldOut = (grid, targets) } else { fitter.add(grid, targets: targets) }
        }
        let fitted = try #require(fitter.solve(family: "test", ridge: 0, note: ""))
        let maxError = zip(fitted.weights, truth.weights).map { abs($0 - $1) }.max() ?? 1
        // 8-bit targets limit the precision.
        #expect(maxError < 0.01)
        let (grid, targets) = try #require(heldOut)
        #expect(LatentRGBFitter.rmse(fitted, grid: grid, targets: targets) < 1)
    }

    @Test func chwIsTransposedToPositionsByChannels() {
        // 2 channels on a 3×2 grid: channel 0 = 0…5, channel 1 = 10…15.
        let chw: [Float] = [0, 1, 2, 3, 4, 5, 10, 11, 12, 13, 14, 15]
        let grid = LatentGrid.fromCHW(chw, channels: 2, width: 3, height: 2, step: 1, totalSteps: 2)
        #expect(grid.values == [0, 10, 1, 11, 2, 12, 3, 13, 4, 14, 5, 15])
    }

    @Test func decodedImageIsScaledDownKeepingAspect() throws {
        let frame = try #require(LatentPreview.frame(
            LatentGrid(step: 1, totalSteps: 1, gridWidth: 4, gridHeight: 2, channels: 1, values: [Float](repeating: 0, count: 8)),
            factors: LatentRGBFactors(family: "t", channels: 1, block: 1, weights: [0, 0, 0, 1, 0, 0], note: "")))
        // Bias (1, 0, 0) → pure red.
        #expect(frame.rgba.prefix(4) == Data([255, 0, 0, 255]))
        let scaled = try #require(LatentPreview.frame(image(frame), step: 1, totalSteps: 1, maxSide: 2))
        #expect(scaled.width == 2 && scaled.height == 1 && !scaled.isApproximate)
    }
}

@Suite("Live preview: bundled factors")
struct BundledFactorsTests {
    @Test func fittedFactorsAreBundled() throws {
        let flux = try #require(LatentRGBFactors.bundled(family: "flux2"))
        #expect(flux.channels == 128 && flux.block == 1)
        #expect(LatentRGBFactors.bundled(family: "unknown") == nil)
    }
}
