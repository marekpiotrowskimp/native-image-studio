import Accelerate
import CoreGraphics
import Domain
import Foundation

/// Latents of one denoising step as `positions × channels` (row-major, positions row by row
/// from the top-left of the latent grid).
public struct LatentGrid: Sendable {
    public let step: Int
    public let totalSteps: Int
    public let gridWidth: Int
    public let gridHeight: Int
    public let channels: Int
    public let values: [Float]

    public init(step: Int, totalSteps: Int, gridWidth: Int, gridHeight: Int, channels: Int, values: [Float]) {
        precondition(values.count == gridWidth * gridHeight * channels, "latent buffer does not match the grid")
        self.step = step
        self.totalSteps = totalSteps
        self.gridWidth = gridWidth
        self.gridHeight = gridHeight
        self.channels = channels
        self.values = values
    }

    /// From a `[channels, height, width]` buffer (NCHW without the batch axis).
    public static func fromCHW(_ chw: [Float], channels: Int, width: Int, height: Int,
                               step: Int, totalSteps: Int) -> LatentGrid {
        var hwc = [Float](repeating: 0, count: chw.count)
        let plane = width * height
        chw.withUnsafeBufferPointer { src in
            hwc.withUnsafeMutableBufferPointer { dst in
                // Transpose (channels × plane) → (plane × channels).
                vDSP_mtrans(src.baseAddress!, 1, dst.baseAddress!, 1, vDSP_Length(plane), vDSP_Length(channels))
            }
        }
        return LatentGrid(step: step, totalSteps: totalSteps, gridWidth: width, gridHeight: height,
                          channels: channels, values: hwc)
    }
}

/// Linear latent → RGB map of one VAE, fitted by least squares on real generations
/// (`nis-poc preview-fit`). Output is sRGB in 0…1.
public struct LatentRGBFactors: Sendable, Codable, Equatable {
    /// Model family whose VAE this map belongs to ("sdxl", "flux2", "zimage").
    public let family: String
    public let channels: Int
    /// Output pixels per latent position along each axis (FLUX.2 packed 2×2 tokens: 2).
    public let block: Int
    /// `(channels + 1) × (3·block²)` row-major; the last row is the bias.
    /// Column `(by·block + bx)·3 + c` is colour `c` of sub-pixel (bx, by).
    public let weights: [Float]
    /// Fit provenance shown in docs: samples, held-out RMSE (0…255), source models.
    public let note: String

    public init(family: String, channels: Int, block: Int, weights: [Float], note: String) {
        precondition(weights.count == (channels + 1) * 3 * block * block, "weights do not match the shape")
        self.family = family
        self.channels = channels
        self.block = block
        self.weights = weights
        self.note = note
    }

    var outputs: Int { 3 * block * block }

    /// Bundled factors for a model family, nil when none were fitted.
    public static func bundled(family: String) -> LatentRGBFactors? {
        // Same lookup as the model manifests (a subdirectory lookup misses in xcodebuild products).
        guard let dir = Bundle.module.url(forResource: "LatentRGB", withExtension: nil),
              let data = try? Data(contentsOf: dir.appendingPathComponent("\(family).json")) else { return nil }
        return try? JSONDecoder().decode(LatentRGBFactors.self, from: data)
    }
}

public enum LatentPreview {
    /// RGB estimate of `grid` (one pixel per latent position × block²).
    /// `smooth`: separable [1 2 1] blur; a per-position linear map leaves per-token colour noise.
    public static func frame(_ grid: LatentGrid, factors: LatentRGBFactors, smooth: Bool = true) -> PreviewFrame? {
        guard grid.channels == factors.channels else { return nil }
        let positions = grid.gridWidth * grid.gridHeight
        let k = factors.outputs
        let c = factors.channels
        // Y = X · W[0..<c] + bias
        var y = [Float](repeating: 0, count: positions * k)
        grid.values.withUnsafeBufferPointer { x in
            factors.weights.withUnsafeBufferPointer { w in
                y.withUnsafeMutableBufferPointer { out in
                    vDSP_mmul(x.baseAddress!, 1, w.baseAddress!, 1, out.baseAddress!, 1,
                              vDSP_Length(positions), vDSP_Length(k), vDSP_Length(c))
                }
            }
        }
        let bias = Array(factors.weights[(c * k)...])
        let b = factors.block
        let width = grid.gridWidth * b
        let height = grid.gridHeight * b
        var rgb = [Float](repeating: 0, count: width * height * 3)
        for gy in 0..<grid.gridHeight {
            for gx in 0..<grid.gridWidth {
                let row = (gy * grid.gridWidth + gx) * k
                for by in 0..<b {
                    for bx in 0..<b {
                        let pixel = ((gy * b + by) * width + gx * b + bx) * 3
                        let column = (by * b + bx) * 3
                        for ch in 0..<3 { rgb[pixel + ch] = y[row + column + ch] + bias[column + ch] }
                    }
                }
            }
        }
        if smooth { rgb = blur121(rgb, width: width, height: height) }
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for i in 0..<(width * height) {
            for ch in 0..<3 { rgba[i * 4 + ch] = UInt8(max(0, min(255, (rgb[i * 3 + ch] * 255).rounded()))) }
        }
        return PreviewFrame(step: grid.step, totalSteps: grid.totalSteps, width: width, height: height,
                            rgba: Data(rgba), isApproximate: true)
    }

    /// Separable [1 2 1]/4 blur of an RGB float image (edges clamped).
    static func blur121(_ src: [Float], width: Int, height: Int) -> [Float] {
        var tmp = src
        var out = src
        for y in 0..<height {
            for x in 0..<width {
                let l = max(0, x - 1), r = min(width - 1, x + 1)
                for ch in 0..<3 {
                    tmp[(y * width + x) * 3 + ch] = (src[(y * width + l) * 3 + ch] + 2 * src[(y * width + x) * 3 + ch]
                        + src[(y * width + r) * 3 + ch]) / 4
                }
            }
        }
        for y in 0..<height {
            let u = max(0, y - 1), d = min(height - 1, y + 1)
            for x in 0..<width {
                for ch in 0..<3 {
                    out[(y * width + x) * 3 + ch] = (tmp[(u * width + x) * 3 + ch] + 2 * tmp[(y * width + x) * 3 + ch]
                        + tmp[(d * width + x) * 3 + ch]) / 4
                }
            }
        }
        return out
    }

    /// A decoded image scaled down to at most `maxSide` pixels, as a preview frame.
    public static func frame(_ image: CGImage, step: Int, totalSteps: Int, maxSide: Int = 384) -> PreviewFrame? {
        let scale = min(1, Double(maxSide) / Double(max(image.width, image.height)))
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        guard let pixels = rgbaPixels(image, width: width, height: height) else { return nil }
        return PreviewFrame(step: step, totalSteps: totalSteps, width: width, height: height,
                            rgba: Data(pixels), isApproximate: false)
    }

    /// `image` resampled to `width × height`, 8-bit sRGB RGBA, rows from the top.
    public static func rgbaPixels(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let ok = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { return nil }
        for i in stride(from: 3, to: pixels.count, by: 4) { pixels[i] = 255 }
        return pixels
    }

    /// Full-decode previews every few steps: about four per run.
    public static func fullDecodeInterval(steps: Int) -> Int { max(1, steps / 4) }

    /// Developer hook for `nis-poc preview-fit`: receives every latent grid an engine reports.
    public static var tap: (@Sendable (LatentGrid) -> Void)? {
        get { tapLock.withLock { tapHandler } }
        set { tapLock.withLock { tapHandler = newValue } }
    }

    private static let tapLock = NSLock()
    nonisolated(unsafe) private static var tapHandler: (@Sendable (LatentGrid) -> Void)?
}

/// Least-squares fit of `LatentRGBFactors` from (final latents, decoded image) pairs.
public struct LatentRGBFitter {
    public let channels: Int
    public let block: Int
    private var xtx: [Double]
    private var xty: [Double]
    public private(set) var samples = 0

    public init(channels: Int, block: Int) {
        self.channels = channels
        self.block = block
        let n = channels + 1
        xtx = [Double](repeating: 0, count: n * n)
        xty = [Double](repeating: 0, count: n * 3 * block * block)
    }

    var outputs: Int { 3 * block * block }

    /// Targets: `image` resampled to the latent grid × block, in 0…1.
    public static func targets(_ image: CGImage, grid: LatentGrid, block: Int) -> [Double]? {
        let width = grid.gridWidth * block
        let height = grid.gridHeight * block
        guard let pixels = LatentPreview.rgbaPixels(image, width: width, height: height) else { return nil }
        let k = 3 * block * block
        var t = [Double](repeating: 0, count: grid.gridWidth * grid.gridHeight * k)
        for gy in 0..<grid.gridHeight {
            for gx in 0..<grid.gridWidth {
                for by in 0..<block {
                    for bx in 0..<block {
                        let pixel = ((gy * block + by) * width + gx * block + bx) * 4
                        for ch in 0..<3 {
                            t[(gy * grid.gridWidth + gx) * k + (by * block + bx) * 3 + ch] = Double(pixels[pixel + ch]) / 255
                        }
                    }
                }
            }
        }
        return t
    }

    public mutating func add(_ grid: LatentGrid, targets t: [Double]) {
        precondition(grid.channels == channels)
        let n = channels + 1
        let k = outputs
        var row = [Double](repeating: 1, count: n)
        for p in 0..<(grid.gridWidth * grid.gridHeight) {
            for i in 0..<channels { row[i] = Double(grid.values[p * channels + i]) }
            for i in 0..<n {
                let ri = row[i]
                for j in i..<n { xtx[i * n + j] += ri * row[j] }
                for o in 0..<k { xty[i * k + o] += ri * t[p * k + o] }
            }
        }
        samples += grid.gridWidth * grid.gridHeight
    }

    /// Solves (XᵀX + λI)·W = XᵀY by Cholesky. Nil when the system is singular.
    public func solve(family: String, ridge: Double = 1e-3, note: String) -> LatentRGBFactors? {
        let n = channels + 1
        let k = outputs
        var a = xtx
        // Ridge on the channel weights (not the bias), relative to their mean diagonal.
        var diagonal = 0.0
        for i in 0..<channels { diagonal += xtx[i * n + i] }
        let meanDiagonal = diagonal / Double(max(channels, 1))
        for i in 0..<n {
            for j in 0..<i { a[i * n + j] = a[j * n + i] }
            if i < channels { a[i * n + i] += ridge * meanDiagonal }
        }
        // Cholesky A = L·Lᵀ (lower triangle in place).
        for j in 0..<n {
            var d = a[j * n + j]
            for p in 0..<j { d -= a[j * n + p] * a[j * n + p] }
            guard d > 0 else { return nil }
            a[j * n + j] = d.squareRoot()
            for i in (j + 1)..<n {
                var s = a[i * n + j]
                for p in 0..<j { s -= a[i * n + p] * a[j * n + p] }
                a[i * n + j] = s / a[j * n + j]
            }
        }
        var w = [Double](repeating: 0, count: n * k)
        for o in 0..<k {
            var z = [Double](repeating: 0, count: n)
            for i in 0..<n {
                var s = xty[i * k + o]
                for p in 0..<i { s -= a[i * n + p] * z[p] }
                z[i] = s / a[i * n + i]
            }
            for i in stride(from: n - 1, through: 0, by: -1) {
                var s = z[i]
                for p in (i + 1)..<n { s -= a[p * n + i] * w[p * k + o] }
                w[i * k + o] = s / a[i * n + i]
            }
        }
        return LatentRGBFactors(family: family, channels: channels, block: block, weights: w.map { Float($0) }, note: note)
    }

    /// Root-mean-square error in 0…255 of `factors` on `grid` against `targets`.
    public static func rmse(_ factors: LatentRGBFactors, grid: LatentGrid, targets t: [Double]) -> Double {
        guard let frame = LatentPreview.frame(grid, factors: factors, smooth: false) else { return .infinity }
        let b = factors.block
        let k = 3 * b * b
        var sum = 0.0
        var count = 0
        frame.rgba.withUnsafeBytes { raw in
            let px = raw.bindMemory(to: UInt8.self)
            for gy in 0..<grid.gridHeight {
                for gx in 0..<grid.gridWidth {
                    for by in 0..<b {
                        for bx in 0..<b {
                            let pixel = ((gy * b + by) * frame.width + gx * b + bx) * 4
                            for ch in 0..<3 {
                                let e = Double(px[pixel + ch]) - t[(gy * grid.gridWidth + gx) * k + (by * b + bx) * 3 + ch] * 255
                                sum += e * e
                                count += 1
                            }
                        }
                    }
                }
            }
        }
        return (sum / Double(max(count, 1))).squareRoot()
    }
}
