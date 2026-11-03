import CoreMLEngine
import Domain
import CoreGraphics
import Foundation
import ImageIO
import Application
import Infrastructure
import MLXEngine
import PromptAssistant

// Etap 1 proof-of-concept driver. Build with xcodebuild (MLX needs the Metal library):
//   scripts/build-cli.sh && scripts/run-etap1.sh

struct Options {
    var command = "help"
    var modelID = "flux2-klein-4b"
    var prompt = "a photorealistic portrait of an elderly fisherman in a yellow raincoat on a pier at dawn, 85mm, shallow depth of field"
    var editPrompt = "make it a snowy winter evening with warm street lights"
    var editPromptGiven = false
    var size = 1024
    var steps: Int?
    var count = 10
    var seed: UInt64 = 1
    var strength: Float = 0.6
    var images: [URL] = []
    var maxRefs = 4
    var cancelAfterStep = 2
    var outDir = URL(fileURLWithPath: "out", isDirectory: true)
    var benchLog = URL(fileURLWithPath: "docs/bench/etap1.jsonl")
    var note: String?
    var memoryOptimization: String?
    var keepTextEncoder: String?
    /// Override the manifest limit to probe what the model actually accepts.
    var allowRefs: Int?
    var computeUnits: String?
    var backendOptions: [String: String] = [:]
    var maskRect: [Double] = [0.25, 0.25, 0.5, 0.5]
    var loras: [LoRAReference] = []
    var livePreview: LivePreviewMode = .off
    /// preview-fit: where the fitted factors are written.
    var factorsOut: URL?

    static func parse(_ args: [String]) -> Options {
        var o = Options()
        var it = args.dropFirst().makeIterator()
        if let cmd = it.next() { o.command = cmd }
        while let a = it.next() {
            switch a {
            case "--model": o.modelID = it.next()!
            case "--prompt": o.prompt = it.next()!
            case "--edit-prompt": o.editPrompt = it.next()!; o.editPromptGiven = true
            case "--size": o.size = Int(it.next()!)!
            case "--steps": o.steps = Int(it.next()!)!
            case "--count": o.count = Int(it.next()!)!
            case "--seed": o.seed = UInt64(it.next()!)!
            case "--strength": o.strength = Float(it.next()!)!
            case "--image": o.images.append(URL(fileURLWithPath: it.next()!))
            case "--max-refs": o.maxRefs = Int(it.next()!)!
            case "--cancel-after-step": o.cancelAfterStep = Int(it.next()!)!
            case "--out": o.outDir = URL(fileURLWithPath: it.next()!, isDirectory: true)
            case "--bench-log": o.benchLog = URL(fileURLWithPath: it.next()!)
            case "--note": o.note = it.next()!
            case "--memopt": o.memoryOptimization = it.next()!
            case "--keep-te": o.keepTextEncoder = it.next()!
            case "--allow-refs": o.allowRefs = Int(it.next()!)!
            case "--compute-units": o.computeUnits = it.next()!
            case "--opt":
                let kv = it.next()!.split(separator: "=", maxSplits: 1).map(String.init)
                o.backendOptions[kv[0]] = kv[1]
            case "--mask-rect": o.maskRect = it.next()!.split(separator: ",").map { Double($0)! }
            case "--preview": o.livePreview = LivePreviewMode(rawValue: it.next()!)!
            case "--factors-out": o.factorsOut = URL(fileURLWithPath: it.next()!)
            case "--lora": o.loras.append(LoRAReference(fileURL: URL(fileURLWithPath: it.next()!), scale: 1))
            case "--lora-scale":
                let v = Float(it.next()!)!
                if let last = o.loras.popLast() { o.loras.append(LoRAReference(fileURL: last.fileURL, scale: v)) }
            default: fatalError("Unknown option \(a)")
            }
        }
        return o
    }
}

let usage = """
    nis-poc <command> [options]
      download                 fetch weights for --model
      t2i                      --count N text-to-image runs (seeds --seed…)
      edit                     reference edit with --image (1..N) and --edit-prompt
      i2i                      image-to-image with --image and --strength
      inpaint                  repaint --mask-rect x,y,w,h of --image with --edit-prompt
      refscale                 reference edit with 1…--max-refs copies of --image, measuring memory
      cancel                   cancel after --cancel-after-step, measure stop latency
      unload                   load → generate → unload, measure memory return
      preview-fit              fit the live-preview latent→RGB map of --model's VAE (--count prompts, --factors-out)
      queue                    --count t2i jobs through the coordinator (as the app), memory before each
      prompt-download          fetch the prompt assistant LLM
      prompt                   write a prompt for --model from the idea in --prompt
                               (--edit-prompt: refine that prompt instead; --count N repeats)
    """

@MainActor
final class PoC {
    let o: Options
    let repo: ModelRepository
    let images: ImageRepository
    let mlx: MLXGenerationEngine
    let coreml: CoreMLGenerationEngine
    let log: BenchmarkLog
    var descriptor: ModelDescriptor!
    var coldLoad: Double?

    init(_ o: Options) {
        self.o = o
        repo = ModelRepository()
        images = ImageRepository(outputDirectory: o.outDir)
        mlx = MLXGenerationEngine(models: repo, images: images)
        coreml = CoreMLGenerationEngine(models: repo, images: images)
        log = BenchmarkLog(fileURL: o.benchLog)
    }

    func setUp() async throws {
        var d = try await repo.descriptor(id: o.modelID)
        if let m = o.memoryOptimization { d.backendOptions["memoryOptimization"] = m }
        if let k = o.keepTextEncoder { d.backendOptions["keepTextEncoderLoaded"] = k }
        if let n = o.allowRefs { d.maxReferenceImages = n }
        if let cu = o.computeUnits { d.backendOptions["computeUnits"] = cu }
        d.backendOptions.merge(o.backendOptions) { _, new in new }
        await repo.register(d)
        descriptor = d
        await mlx.setLivePreview(o.livePreview)
        await coreml.setLivePreview(o.livePreview)
    }

    var steps: Int { o.steps ?? descriptor.defaultSteps }

    var engine: any ImageGenerationEngine { descriptor.backend == .mlx ? mlx : coreml }

    var installer: any ModelWeightsProvider { descriptor.backend == .mlx ? mlx : coreml }

    func lastLoadSeconds() async -> Double? {
        descriptor.backend == .mlx ? await mlx.lastLoadSeconds : await coreml.lastLoadSeconds
    }

    /// Backend-neutral view of the engine's last run.
    func lastStats() async -> (secondsPerStep: Double?, mlxPeakGB: Double?, footprintGB: Double)? {
        if descriptor.backend == .mlx {
            guard let s = await mlx.lastRunStats else { return nil }
            return (s.secondsPerStep, s.peakGPUGB, s.footprintAfterGB)
        }
        guard let s = await coreml.lastRunStats else { return nil }
        return (s.secondsPerStep, nil, s.footprintAfterGB)
    }

    func footprint() -> Double { DarwinMemoryProbe.processFootprint().gigabytes }

    func ensureLoaded() async throws {
        if await engine.loadedModelID() == o.modelID { return }
        let before = footprint()
        try await engine.loadModel(id: o.modelID)
        coldLoad = await lastLoadSeconds()
        print(String(format: "[load] %@ cold load %.2fs, footprint %.2f → %.2f GB", o.modelID, coldLoad ?? -1, before, footprint()))
    }

    func request(_ mode: GenerationMode, inputs: [URL], prompt: String, seed: UInt64, width: Int? = nil, height: Int? = nil) -> GenerationRequest {
        GenerationRequest(
            modelID: o.modelID, mode: mode,
            inputImages: inputs.enumerated().map { InputImage(sourceURL: $1, role: $0 == 0 ? .primary : .reference) },
            prompt: prompt, width: width ?? o.size, height: height ?? o.size,
            steps: steps, guidance: descriptor.defaultGuidance, seed: seed, loras: o.loras)
    }

    /// Output size following the first input's aspect ratio.
    func sizeFor(_ url: URL) async throws -> (Int, Int) {
        let s = try ImageInputProcessor().orientedSize(of: url)
        let caps = await engine.capabilities(forModel: o.modelID)
        let t = ImageInputProcessor.targetSize(aspectRatio: s.aspectRatio, targetEdge: o.size, multiple: caps?.dimensionMultiple ?? 32,
                                               minDimension: caps?.minDimension ?? 256, maxDimension: caps?.maxDimension ?? 2048)
        return (t.width, t.height)
    }

    @discardableResult
    func run(_ req: GenerationRequest, note: String? = nil, cancelAfter: Int? = nil) async throws -> GeneratedImage? {
        var caps = await engine.capabilities(forModel: o.modelID) ?? descriptor.engineCapabilities(cancellation: .perStep)
        if let n = o.allowRefs { caps.maxReferenceImages = n }
        try RequestValidator().validate(req, capabilities: caps)
        try await ensureLoaded()
        let load = coldLoad
        coldLoad = nil
        let stream = try await engine.generate(request: req)
        var result: GeneratedImage?
        var cancelIssuedAt: ContinuousClock.Instant?
        var outcome = "completed"
        var previews = 0
        var lastPreview: PreviewFrame?
        do {
            for try await e in stream {
                switch e {
                case .preview(let frame):
                    previews += 1
                    lastPreview = frame
                    let url = o.outDir.appendingPathComponent("preview-s\(req.seed)-step\(frame.step).png")
                    try? FileManager.default.createDirectory(at: o.outDir, withIntermediateDirectories: true)
                    try? PreviewPNG.write(frame, to: url)
                    print("  preview step \(frame.step)/\(frame.totalSteps) \(frame.width)×\(frame.height)\(frame.isApproximate ? " approx" : " decoded")")
                case .step(let c, let t):
                    print("  step \(c)/\(t)")
                    if let n = cancelAfter, c == n, cancelIssuedAt == nil {
                        cancelIssuedAt = .now
                        await engine.cancel(requestID: req.id)
                    }
                case .completed(let img): result = img
                default: break
                }
            }
        } catch GenerationError.cancelled {
            outcome = "cancelled"
        }
        let stats = await lastStats()
        var cancelLatency: Double?
        if let t = cancelIssuedAt {
            cancelLatency = (ContinuousClock.now - t).secondsValue
        }
        let total = result?.elapsedSeconds ?? 0
        let rec = BenchmarkRecord(
            model: o.modelID, backend: descriptor.backend.rawValue, mode: req.mode.kind.rawValue,
            inputImageCount: req.inputImages.count, quantization: descriptor.quantization,
            width: req.width, height: req.height, steps: req.steps, seed: req.seed,
            coldLoadSeconds: load, generationSeconds: total, secondsPerStep: stats?.secondsPerStep ?? 0,
            peakMemoryGB: stats?.mlxPeakGB ?? 0, footprintGB: stats?.footprintGB ?? footprint(),
            note: [note, o.note, String(format: "process peak %.2f GB", DarwinMemoryProbe.processPeakFootprint().gigabytes), cancelLatency.map { String(format: "cancel→stop %.2fs", $0) }, outcome == "cancelled" ? "cancelled" : nil]
                .compactMap { $0 }.joined(separator: "; "))
        try log.append(rec)
        print(BenchmarkRecord.markdownHeader)
        print(rec.markdownRow)
        if let result { print("  → \(result.fileURL.path)") }
        if let lastPreview, let result {
            let url = result.fileURL.deletingPathExtension().appendingPathExtension("preview.png")
            try PreviewPNG.write(lastPreview, to: url)
            print("  previews: \(previews), last → \(url.path)")
        }
        return result
    }

    // MARK: Commands

    func download() async throws {
        print("Downloading weights for \(o.modelID)…")
        let last = LastPrint()
        try await installer.install(modelID: o.modelID) { fraction, message in
            if last.shouldPrint(fraction) { print(String(format: "  %5.1f%% %@", fraction * 100, message)) }
        }
        print("done")
    }

    func t2i() async throws {
        for i in 0..<o.count {
            print("[t2i] \(i + 1)/\(o.count) seed \(o.seed + UInt64(i))")
            try await run(request(.textToImage, inputs: [], prompt: o.prompt, seed: o.seed + UInt64(i)))
        }
    }

    func edit() async throws {
        guard let first = o.images.first else { fatalError("--image required") }
        let (w, h) = try await sizeFor(first)
        try await run(request(.referenceEdit, inputs: o.images, prompt: o.editPrompt, seed: o.seed, width: w, height: h),
                      note: "refs=\(o.images.count)")
    }

    func i2i() async throws {
        guard let first = o.images.first else { fatalError("--image required") }
        let (w, h) = try await sizeFor(first)
        try await run(request(.imageToImage(strength: o.strength), inputs: [first], prompt: o.editPrompt, seed: o.seed, width: w, height: h),
                      note: "strength=\(o.strength)")
    }

    /// Inpaint a normalized rectangle (`--mask-rect x,y,w,h`, top-left origin) of `--image`.
    func inpaint() async throws {
        guard let first = o.images.first else { fatalError("--image required") }
        let (w, h) = try await sizeFor(first)
        let size = try ImageInputProcessor().orientedSize(of: first)
        let r = o.maskRect
        let ctx = CGContext(data: nil, width: size.width, height: size.height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height))
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: r[0] * Double(size.width), y: (1 - r[1] - r[3]) * Double(size.height),
                        width: r[2] * Double(size.width), height: r[3] * Double(size.height)))
        let maskURL = o.outDir.appendingPathComponent("mask-\(UUID().uuidString.prefix(6)).png")
        try FileManager.default.createDirectory(at: o.outDir, withIntermediateDirectories: true)
        let dest = CGImageDestinationCreateWithURL(maskURL as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        let req = request(.inpainting(mask: InputImage(sourceURL: maskURL, role: .mask)), inputs: [first],
                          prompt: o.editPrompt, seed: o.seed, width: w, height: h)
        try await run(req, note: "inpaint rect \(r)")
    }

    func refscale() async throws {
        guard !o.images.isEmpty else { fatalError("--image required") }
        for n in 1...o.maxRefs {
            let inputs = (0..<n).map { o.images[$0 % o.images.count] }
            print("[refscale] \(n) reference image(s)")
            do {
                try await run(request(.referenceEdit, inputs: inputs, prompt: o.editPrompt, seed: o.seed), note: "refscale n=\(n)")
            } catch {
                print("  refs=\(n) FAILED: \(error)")
            }
        }
    }

    /// Prompt assistant through a real coordinator, as in the app (exclusive GPU).
    lazy var assistant: MLXPromptAssistant = {
        let coordinator = GenerationCoordinator(
            registry: EngineRegistry([mlx, coreml]), models: repo,
            memory: MemoryBudgetManager(probe: DarwinMemoryProbe(gpu: MLXGPUMemory())))
        return MLXPromptAssistant(coordinator: coordinator)
    }()

    func promptDownload() async throws {
        let printer = LastPrint()
        try await assistant.install { f, m in
            if printer.shouldPrint(f) { print(String(format: "  %5.1f%% %@", f * 100, m)) }
        }
        print("done")
    }

    func prompt() async throws {
        let style = descriptor.effectivePromptStyle
        print("[prompt] \(o.modelID) style \(style.rawValue)")
        for i in 0..<max(1, o.count) {
            let start = ContinuousClock.now
            var first: Duration?
            var result = ""
            let request = PromptDraftRequest(
                idea: o.prompt, currentPrompt: o.editPromptGiven ? o.editPrompt : nil, style: style)
            for try await event in await assistant.write(request) {
                switch event {
                case .partial: if first == nil { first = ContinuousClock.now - start }
                case .finished(let text): result = text
                case .waitingForGPU, .loadingModel: break
                }
            }
            let total = (ContinuousClock.now - start).secondsValue
            let load = i == 0 ? await assistant.lastLoadSeconds : nil
            print(String(format: "[prompt %d] total %.2fs, load %@, first token %.2fs, %d words, footprint %.2f GB, process peak %.2f GB",
                         i + 1, total, load.map { String(format: "%.2fs", $0) } ?? "–", first?.secondsValue ?? -1,
                         result.split(separator: " ").count, footprint(), DarwinMemoryProbe.processPeakFootprint().gigabytes))
            print(result)
        }
        let gpu = MLXGPUMemory()
        print(String(format: "[prompt] before release: footprint %.2f GB, MLX active %.2f GB, cache %.2f GB",
                     footprint(), gpu.activeBytes.gigabytes, gpu.cacheBytes.gigabytes))
        await assistant.releaseGPU()
        print(String(format: "[prompt] after release: footprint %.2f GB, MLX active %.2f GB, cache %.2f GB",
                     footprint(), gpu.activeBytes.gigabytes, gpu.cacheBytes.gigabytes))
    }

    /// `--count` jobs submitted at once through a real coordinator, as the app does; logs the
    /// memory snapshot the admission check sees before each job starts.
    func queue() async throws {
        let probe = DarwinMemoryProbe(gpu: MLXGPUMemory())
        let memory = MemoryBudgetManager(probe: probe)
        let coordinator = GenerationCoordinator(registry: EngineRegistry([mlx, coreml]), models: repo, memory: memory)
        func state(_ label: String) {
            let snap = probe.snapshot()
            print(String(format: "[queue] %@: footprint %.2f GB, system available %.2f GB, MLX active %.2f / cache %.2f GB, admission sees %.2f GB",
                         label, snap.processFootprintBytes.gigabytes, snap.systemAvailableBytes.gigabytes,
                         snap.gpuActiveBytes.gigabytes, snap.gpuCacheBytes.gigabytes, memory.availableGB(snap)))
        }
        state("start")
        var ids: [UUID] = []
        for i in 0..<max(1, o.count) {
            ids.append(try await coordinator.submit(request(.textToImage, inputs: [], prompt: o.prompt, seed: o.seed + UInt64(i))))
        }
        for (i, id) in ids.enumerated() {
            let final = await coordinator.waitForCompletion(id)
            state("after job \(i + 1) (\(final.label))")
            if case .failed(let message) = final { print("  \(message)") }
        }
        for second in [1, 3, 10] {
            try await Task.sleep(for: .seconds(second == 1 ? 1 : second == 3 ? 2 : 7))
            state("\(second) s after the queue")
        }
    }

    /// Fits the latent→RGB preview map of this model's VAE: `--count` prompts (the last one held
    /// out to report the error), final-step latents against the decoded result.
    func previewFit() async throws {
        let prompts = [
            "a red sports car on a coastal road at noon, blue sea, white clouds",
            "a bowl of oranges, lemons and green apples on a wooden table, soft window light",
            "a snowy mountain village at night, warm yellow windows, deep blue sky",
            "a field of purple lavender under a pink sunset sky",
            "a portrait of a woman in a green dress in a garden, golden hour",
            "a neon-lit city street in the rain, magenta and cyan reflections",
            "a black cat on a white sofa, minimal grey interior",
            "a tropical beach with turquoise water, palm trees and yellow sand",
            "an autumn forest with orange and red leaves, misty morning",
            "a still life of blue and white porcelain with red roses",
        ]
        let count = min(max(2, o.count), prompts.count)
        let box = GridBox()
        LatentPreview.tap = { grid in box.set(grid) }
        defer { LatentPreview.tap = nil }
        var fitter: LatentRGBFitter?
        var heldOut: (LatentGrid, [Double])?
        for (i, prompt) in prompts.prefix(count).enumerated() {
            print("[preview-fit] \(i + 1)/\(count): \(prompt)")
            guard let image = try await run(request(.textToImage, inputs: [], prompt: prompt, seed: o.seed + UInt64(i)),
                                            note: "preview-fit"),
                  let grid = box.take(),
                  let source = CGImageSourceCreateWithURL(image.fileURL as CFURL, nil),
                  let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw GenerationError.backendFailure("preview-fit: no latents or image for prompt \(i + 1)")
            }
            // One colour per latent position: per-sub-pixel maps for FLUX.2's 2×2 packed tokens
            // fitted worse on held-out images and looked noisy.
            let block = 1
            guard let targets = LatentRGBFitter.targets(cg, grid: grid, block: block) else { continue }
            if i == count - 1 {
                heldOut = (grid, targets)
            } else {
                if fitter == nil { fitter = LatentRGBFitter(channels: grid.channels, block: block) }
                fitter!.add(grid, targets: targets)
            }
        }
        guard var fit = fitter, let (grid, targets) = heldOut else { return }
        let family = descriptor.architecture
        guard let draft = fit.solve(family: family, note: "") else { throw GenerationError.backendFailure("singular fit") }
        let rmse = LatentRGBFitter.rmse(draft, grid: grid, targets: targets)
        fit.add(grid, targets: targets)  // final factors use every image
        let note = String(format: "least squares on %d final-step latents of %@ (%@, %d steps, %d×%d); held-out RMSE %.1f/255",
                          count, o.modelID, descriptor.backend.rawValue, steps, o.size, o.size, rmse)
        guard let factors = fit.solve(family: family, note: note) else { throw GenerationError.backendFailure("singular fit") }
        print("[preview-fit] \(note)")
        let out = o.factorsOut ?? URL(fileURLWithPath: "NativeImageStudio/Infrastructure/LivePreview/LatentRGB/\(family).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(factors).write(to: out)
        print("  → \(out.path)")
    }

    func cancel() async throws {
        print("[cancel] t2i, cancel after step \(o.cancelAfterStep)")
        try await run(request(.textToImage, inputs: [], prompt: o.prompt, seed: o.seed), note: "cancel test", cancelAfter: o.cancelAfterStep)
        // Engine must be reusable after a cancel.
        try await run(request(.textToImage, inputs: [], prompt: o.prompt, seed: o.seed), note: "after cancel")
    }

    func unload() async throws {
        try await ensureLoaded()
        try await run(request(.textToImage, inputs: [], prompt: o.prompt, seed: o.seed), note: "before unload")
        let gpu = MLXGPUMemory()
        print(String(format: "[unload] before: footprint %.2f GB, MLX active %.2f GB, cache %.2f GB",
                     footprint(), gpu.activeBytes.gigabytes, gpu.cacheBytes.gigabytes))
        await engine.unloadModel()
        if descriptor.backend == .coreml, let r = await coreml.lastUnloadFootprint {
            print(String(format: "[unload] Core ML: footprint %.2f → %.2f GB", r.before, r.after))
        }
        if descriptor.backend == .mlx, let r = await mlx.lastUnloadReport {
            print(String(format: "[unload] procedure %.2fs: footprint %.2f → %.2f GB, MLX active %.2f → %.2f GB, cache after %.2f GB",
                         r.seconds, r.footprintBeforeGB, r.footprintAfterGB, r.gpuActiveBeforeGB, r.gpuActiveAfterGB, r.gpuCacheAfterGB))
        }
        for delay in [1, 3, 5] {
            try await Task.sleep(for: .seconds(delay == 1 ? 1 : 2))
            print(String(format: "[unload] +%ds: footprint %.2f GB, system available %.2f GB", delay, footprint(), DarwinMemoryProbe.systemAvailable().gigabytes))
        }
        try await ensureLoaded()
        print("[unload] reload cold load: \(coldLoad.map { String(format: "%.2fs", $0) } ?? "-")")
    }
}

final class LastPrint: @unchecked Sendable {
    private let lock = NSLock()
    private var last = -1.0
    func shouldPrint(_ f: Double) -> Bool {
        lock.withLock {
            if f - last >= 0.05 || f >= 1 { last = f; return true }
            return false
        }
    }
}

extension Duration {
    var secondsValue: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}

let options = Options.parse(CommandLine.arguments)
if options.command == "help" { print(usage); exit(0) }
let poc = PoC(options)
do {
    try await poc.setUp()
    switch options.command {
    case "download": try await poc.download()
    case "t2i": try await poc.t2i()
    case "edit": try await poc.edit()
    case "i2i": try await poc.i2i()
    case "refscale": try await poc.refscale()
    case "inpaint": try await poc.inpaint()
    case "cancel": try await poc.cancel()
    case "unload": try await poc.unload()
    case "prompt-download": try await poc.promptDownload()
    case "prompt": try await poc.prompt()
    case "queue": try await poc.queue()
    case "preview-fit": try await poc.previewFit()
    default: print(usage); exit(2)
    }
} catch {
    print("ERROR: \((error as? any LocalizedError)?.errorDescription ?? String(describing: error))")
    exit(1)
}

/// Keeps the latest latent grid reported by an engine (preview-fit).
final class GridBox: @unchecked Sendable {
    private let lock = NSLock()
    private var grid: LatentGrid?
    func set(_ g: LatentGrid) { lock.withLock { grid = g } }
    func take() -> LatentGrid? { lock.withLock { defer { grid = nil }; return grid } }
}

enum PreviewPNG {
    static func write(_ frame: PreviewFrame, to url: URL) throws {
        guard let provider = CGDataProvider(data: frame.rgba as CFData),
              let image = CGImage(width: frame.width, height: frame.height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: frame.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }
}
