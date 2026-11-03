import CoreGraphics
import Domain
import Foundation
import Infrastructure
import MLX
import MLXNN
import Tokenizers
import ZImage

/// Z-Image (Tongyi S3-DiT 6B) adapter over the vendored `ZImage` core of z-image-swift.
///
/// Weights: a base diffusers snapshot (text encoder Qwen3-4B, VAE, tokenizer, scheduler
/// config) plus an optional single-file transformer in ComfyUI layout (e.g. CyberRealistic
/// Z-Image Turbo), converted at load time by `ZImageCheckpoint`. The transformer is
/// quantized after loading (int4 by default).
///
/// Thread-safety: state is only touched from the owning engine actor (serialized).
public final class ZImageAdapter: MLXPipelineAdapter, @unchecked Sendable {
    public let descriptor: ModelDescriptor
    public let capabilities: EngineCapabilities

    private var generator: ZImageGenerator?
    private let baseSnapshot: URL
    private let transformerFile: URL?
    private let transformerBits: Int?
    private let textEncoderBits: Int?

    /// Z-Image works on a 16 px grid; the port's envelope is ≤ 1536² pixels.
    public static let dimensionMultiple = 16

    public static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NativeImageStudio/ZImage", isDirectory: true)
    }

    public init(descriptor: ModelDescriptor) {
        let o = descriptor.backendOptions
        self.descriptor = descriptor
        baseSnapshot = Self.resolve(o["baseSnapshot"] ?? "base")
        transformerFile = o["transformerFile"].map(Self.resolve)
        transformerBits = Int(o["transformerBits"] ?? "4")
        textEncoderBits = o["textEncoderBits"].flatMap(Int.init)
        capabilities = descriptor.engineCapabilities(
            cancellation: .perStep, dimensionMultiple: Self.dimensionMultiple,
            minDimension: 256, maxDimension: 1536, maxSteps: 50)
    }

    /// Relative paths are taken from the app's ZImage directory.
    static func resolve(_ path: String) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        return expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : defaultRoot.appendingPathComponent(expanded)
    }

    // MARK: Files

    static let baseFiles = [
        "scheduler/scheduler_config.json", "text_encoder/config.json",
        "text_encoder/model.safetensors.index.json", "tokenizer/tokenizer.json",
        "tokenizer/tokenizer_config.json", "vae/config.json", "vae/diffusion_pytorch_model.safetensors",
    ]

    public func isInstalled() -> Bool {
        let fm = FileManager.default
        let base = Self.baseFiles.allSatisfy { fm.fileExists(atPath: baseSnapshot.appendingPathComponent($0).path) }
        let shards = ((try? fm.contentsOfDirectory(atPath: baseSnapshot.appendingPathComponent("text_encoder").path)) ?? [])
            .filter { $0.hasSuffix(".safetensors") }.count >= 3
        let transformer = transformerFile.map { fm.fileExists(atPath: $0.path) }
            ?? fm.fileExists(atPath: baseSnapshot.appendingPathComponent("transformer").path)
        return base && shards && transformer
    }

    public var ownedWeightsURL: URL? { transformerFile }
    public var sharedComponents: [String] { ["Z-Image base (Qwen3-4B text encoder, VAE, tokenizer)"] }

    static let textEncoderShards = [
        "text_encoder/model-00001-of-00003.safetensors", "text_encoder/model-00002-of-00003.safetensors",
        "text_encoder/model-00003-of-00003.safetensors", "text_encoder/generation_config.json",
        "tokenizer/merges.txt", "tokenizer/vocab.json", "model_index.json", "transformer/config.json",
    ]

    /// Downloads missing files: the base snapshot from `baseRepo` and the single-file
    /// transformer from `transformerURL`. Existing files are skipped.
    public func prepareWeights(progress: (@Sendable (Double, String) -> Void)?) async throws {
        let o = descriptor.backendOptions
        var jobs: [(URL, URL)] = []
        if let repo = o["baseRepo"] {
            for file in Self.baseFiles + Self.textEncoderShards {
                jobs.append((URL(string: "https://huggingface.co/\(repo)/resolve/main/\(file)")!, baseSnapshot.appendingPathComponent(file)))
            }
        }
        if let file = transformerFile, let remote = o["transformerURL"].flatMap(URL.init(string:)) {
            jobs.append((remote, file))
        }
        let fm = FileManager.default
        for (i, (remote, local)) in jobs.enumerated() where !fm.fileExists(atPath: local.path) {
            progress?(Double(i) / Double(jobs.count), local.lastPathComponent)
            try fm.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
            let (tmp, response) = try await URLSession.shared.download(from: remote)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw GenerationError.backendFailure("Błąd pobierania \(remote.lastPathComponent).")
            }
            try fm.moveItem(at: tmp, to: local)
        }
        guard isInstalled() else {
            throw GenerationError.modelNotFound("\(descriptor.name): niekompletne wagi w \(Self.defaultRoot.path).")
        }
        progress?(1, "Gotowe")
    }

    // MARK: Load

    public func load() async throws {
        guard generator == nil else { return }
        guard isInstalled() else { try await prepareWeights(progress: nil); return }

        let transformer: ZImageTransformer2DModel
        if let file = transformerFile {
            transformer = try ZImageCheckpoint.loadComfyTransformer(file)
        } else {
            transformer = try ZImageWeights.loadTransformer(snapshotPath: baseSnapshot.path, dtype: .bfloat16)
        }
        if let bits = transformerBits, bits == 4 || bits == 8 {
            ZImageWeights.quantizeDiT(transformer, bits: bits)
        }
        Memory.clearCache()

        let vae = try ZImageWeights.loadVAE(snapshotPath: baseSnapshot.path, dtype: .float32)
        let encoder = try ZImageWeights.loadTextEncoder(snapshotPath: baseSnapshot.path, dtype: .bfloat16)
        if let bits = textEncoderBits, bits == 4 || bits == 8 {
            quantize(model: encoder, filter: { _, module in module is Linear ? (64, bits, .affine) : nil })
            eval(encoder)
        }
        Memory.clearCache()
        let tokenizer = try await AutoTokenizer.from(modelFolder: baseSnapshot.appendingPathComponent("tokenizer"))
        let (shift, dynamic) = Self.schedulerConfig(baseSnapshot)
        generator = ZImageGenerator(
            transformer: transformer, vae: vae,
            textEncoder: ZImageTextEncoder(encoder: encoder, tokenizer: tokenizer),
            schedulerShift: shift, schedulerDynamic: dynamic, transformerDtype: .bfloat16)
    }

    static func schedulerConfig(_ snapshot: URL) -> (Float, Bool) {
        struct Cfg: Decodable { var shift: Float?; var use_dynamic_shifting: Bool? }
        let url = snapshot.appendingPathComponent("scheduler/scheduler_config.json")
        guard let data = try? Data(contentsOf: url), let c = try? JSONDecoder().decode(Cfg.self, from: data) else { return (3, false) }
        return (c.shift ?? 3, c.use_dynamic_shifting ?? false)
    }

    // MARK: Run

    public func run(_ request: GenerationRequest, inputs: PreparedInputs, callbacks: PipelineCallbacks) async throws -> CGImage {
        guard let generator else { throw GenerationError.modelNotLoaded }
        guard request.loras.isEmpty else { throw GenerationError.backendFailure("Z-Image: LoRA nie jest obsługiwane.") }
        // The core polls `Task.isCancelled` once per step; turning the engine's flag into a
        // task cancellation from the step callback stops it at the next step boundary.
        let onStep: (Int, Int) -> Void = { current, total in
            callbacks.onStep(current, total)
            if callbacks.isCancelled() { withUnsafeCurrentTask { $0?.cancel() } }
        }
        // Latents [1, 16, H/8, W/8] → positions × channels for the approximate preview.
        let onLatents: ((Int, Int, MLXArray) -> Void)? = callbacks.wantsLatents ? { done, total, latents in
            let shape = latents.shape
            let hwc = latents[0].transposed(1, 2, 0).asType(.float32)
            let grid = LatentGrid(step: done, totalSteps: total, gridWidth: shape[3], gridHeight: shape[2],
                                  channels: shape[1], values: hwc.asArray(Float.self))
            callbacks.report(grid)
        } : nil
        let negative = request.negativePrompt.flatMap { $0.isEmpty ? nil : $0 }
        let result: (pixels: [UInt8], width: Int, height: Int)
        switch request.mode {
        case .textToImage:
            result = generator.generate(
                prompt: request.prompt, negativePrompt: negative, width: request.width, height: request.height,
                steps: request.steps, guidanceScale: request.guidance, seed: request.seed,
                onStep: onStep, onLatents: onLatents)
        case .imageToImage(let strength):
            guard let source = inputs.images.first else { throw GenerationError.inputProcessingFailed("brak obrazu") }
            result = generator.generateImg2Img(
                prompt: request.prompt, negativePrompt: negative, image: Self.tensor(from: source),
                width: request.width, height: request.height, steps: request.steps,
                guidanceScale: request.guidance, strength: strength, seed: request.seed,
                onStep: onStep, onLatents: onLatents)
        case .referenceEdit, .inpainting:
            throw GenerationError.backendFailure("Z-Image obsługuje tylko tekst→obraz i transformację.")
        }
        // Activations of a 1024² run stay in MLX's buffer pool otherwise (measured: +6 GB).
        Memory.clearCache()
        if Task.isCancelled || callbacks.isCancelled() || result.pixels.isEmpty { throw GenerationError.cancelled }
        guard let image = Self.cgImage(rgb: result.pixels, width: result.width, height: result.height) else {
            throw GenerationError.backendFailure("Z-Image: nie udało się utworzyć obrazu.")
        }
        return image
    }

    public func release() async {
        generator = nil
        Memory.clearCache()
    }

    // MARK: Pixel conversion

    /// sRGB CGImage → [1, 3, H, W] in [-1, 1].
    static func tensor(from image: CGImage) -> MLXArray {
        let w = image.width, h = image.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: ImageInputProcessor.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var rgb = [Float](repeating: 0, count: 3 * w * h)
        for p in 0..<(w * h) {
            rgb[p] = Float(buf[p * 4]) / 127.5 - 1
            rgb[w * h + p] = Float(buf[p * 4 + 1]) / 127.5 - 1
            rgb[2 * w * h + p] = Float(buf[p * 4 + 2]) / 127.5 - 1
        }
        return MLXArray(rgb, [1, 3, h, w])
    }

    /// Interleaved RGB8 → opaque sRGB CGImage.
    static func cgImage(rgb: [UInt8], width: Int, height: Int) -> CGImage? {
        guard rgb.count == width * height * 3 else { return nil }
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for i in 0..<(width * height) {
            rgba[i * 4] = rgb[i * 3]
            rgba[i * 4 + 1] = rgb[i * 3 + 1]
            rgba[i * 4 + 2] = rgb[i * 3 + 2]
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: ImageInputProcessor.sRGB, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// Converts single-file ComfyUI Z-Image checkpoints (e.g. CyberRealistic) to the port's
/// parameter layout: strip `model.diffusion_model.`, split fused `attention.qkv` into
/// `to_q/to_k/to_v`, rename `out`→`to_out.0`, `q_norm`/`k_norm`→`norm_q`/`norm_k`,
/// `final_layer.adaLN_modulation.1`→`adaLN_linear` and the t/cap embedder MLPs.
public enum ZImageCheckpoint {
    public static let comfyPrefix = "model.diffusion_model."

    /// Pure key/tensor mapping (testable without weights). `split` divides a fused qkv
    /// tensor into three equal parts along axis 0.
    public static func remap<T>(_ weights: [String: T], split: (T) -> (T, T, T)) -> [String: T] {
        var out: [String: T] = [:]
        for (rawKey, value) in weights {
            var key = rawKey.hasPrefix(comfyPrefix) ? String(rawKey.dropFirst(comfyPrefix.count)) : rawKey
            if key.hasSuffix(".attention.qkv.weight") {
                let base = String(key.dropLast("qkv.weight".count))
                let (q, k, v) = split(value)
                out[base + "to_q.weight"] = q
                out[base + "to_k.weight"] = k
                out[base + "to_v.weight"] = v
                continue
            }
            key = key.replacingOccurrences(of: ".attention.out.", with: ".attention.to_out.0.")
                .replacingOccurrences(of: ".attention.q_norm.", with: ".attention.norm_q.")
                .replacingOccurrences(of: ".attention.k_norm.", with: ".attention.norm_k.")
            for (prefix, replacement) in [
                ("final_layer.adaLN_modulation.1.", "final_layer.adaLN_linear."),
                ("t_embedder.mlp.0.", "t_embedder.mlp_in."),
                ("t_embedder.mlp.2.", "t_embedder.mlp_out."),
                ("cap_embedder.0.", "cap_embedder_norm."),
                ("cap_embedder.1.", "cap_embedder_linear."),
            ] where key.hasPrefix(prefix) {
                key = replacement + key.dropFirst(prefix.count)
                break
            }
            out[key] = value
        }
        return out
    }

    public static func loadComfyTransformer(_ url: URL) throws -> ZImageTransformer2DModel {
        let raw = try MLX.loadArrays(url: url)
        let mapped = remap(raw) { qkv in
            let parts = MLX.split(qkv, parts: 3, axis: 0)
            return (parts[0], parts[1], parts[2])
        }.mapValues { $0.asType(.bfloat16) }
        let model = ZImageTransformer2DModel()
        try model.update(parameters: ModuleParameters.unflattened(mapped), verify: [.all])
        eval(model)
        return model
    }
}
