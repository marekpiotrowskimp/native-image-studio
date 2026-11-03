import CoreGraphics
import Domain
import Foundation
import ImageIO
import Infrastructure
import MLXEngine
import TestSupport
import Testing

/// Real inference on FLUX.2 Klein 4B. Runs only via `scripts/integration-tests.sh`
/// (xcodebuild compiles MLX's Metal shaders; under `swift test` MLX would abort the
/// process) and only when the weights are present locally.
enum IntegrationGate {
    static var weightsDirectory: URL {
        MLXModelStorage.defaultDirectory.appendingPathComponent("black-forest-labs/FLUX.2-klein-4B-klein4b-bf16")
    }

    static var requested: Bool { ProcessInfo.processInfo.environment["NIS_RUN_INTEGRATION"] == "1" }
    static var weightsPresent: Bool { FileManager.default.fileExists(atPath: weightsDirectory.path) }
    static var enabled: Bool { requested && weightsPresent }

    static var reason: Comment {
        if !requested { return "SKIPPED: real inference needs xcodebuild (Metal shaders) — run scripts/integration-tests.sh" }
        return "SKIPPED: FLUX.2 Klein 4B weights not found in \(weightsDirectory.path) — run `nis-poc download`"
    }
}

/// One engine for the whole suite (loading costs seconds and GBs).
actor SharedEngine {
    static let shared = SharedEngine()
    private var engine: MLXGenerationEngine?
    let outputDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("NISIntegration-\(UUID().uuidString.prefix(6))")

    func get() async throws -> MLXGenerationEngine {
        if let engine { return engine }
        let e = MLXGenerationEngine(models: ModelRepository(), images: ImageRepository(outputDirectory: outputDirectory))
        try await e.loadModel(id: "flux2-klein-4b")
        engine = e
        return e
    }
}

func run(_ engine: MLXGenerationEngine, _ request: GenerationRequest, cancelAfterStep: Int? = nil) async throws -> (GeneratedImage?, [Int]) {
    var steps: [Int] = []
    var result: GeneratedImage?
    for try await event in try await engine.generate(request: request) {
        if case .step(let c, _) = event {
            steps.append(c)
            if let n = cancelAfterStep, c == n { await engine.cancel(requestID: request.id) }
        }
        if case .completed(let image) = event { result = image }
    }
    return (result, steps)
}

func pixelSize(_ url: URL) -> (Int, Int)? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return nil }
    return (p[kCGImagePropertyPixelWidth] as? Int ?? 0, p[kCGImagePropertyPixelHeight] as? Int ?? 0)
}

func request(_ mode: GenerationMode, inputs: [URL] = [], prompt: String, width: Int = 512, height: Int = 512, seed: UInt64 = 3) -> GenerationRequest {
    GenerationRequest(
        modelID: "flux2-klein-4b", mode: mode,
        inputImages: inputs.enumerated().map { InputImage(sourceURL: $1, role: $0 == 0 ? .primary : .reference) },
        prompt: prompt, width: width, height: height, steps: 4, guidance: 1, seed: seed)
}

@Suite("MLX engine integration (FLUX.2 Klein 4B)", .serialized, .enabled(if: IntegrationGate.enabled, IntegrationGate.reason))
struct MLXEngineIntegrationTests {
    @Test func textToImageProducesFileWithMetadata() async throws {
        let engine = try await SharedEngine.shared.get()
        let (image, steps) = try await run(engine, request(.textToImage, prompt: "a red apple on a wooden table, photo"))
        let out = try #require(image)
        #expect(steps == [1, 2, 3, 4])
        #expect(pixelSize(out.fileURL)! == (512, 512))
        #expect(out.metadata.modelID == "flux2-klein-4b")
        #expect(FileManager.default.fileExists(atPath: ImageRepository.sidecarURL(for: out.fileURL).path))
    }

    @Test func referenceEditWithTwoImagesKeepsInputsUntouched() async throws {
        let engine = try await SharedEngine.shared.get()
        let (a, _) = try await run(engine, request(.textToImage, prompt: "studio photo of a ceramic mug", seed: 11))
        let (b, _) = try await run(engine, request(.textToImage, prompt: "a field of sunflowers", seed: 12))
        let inputs = [try #require(a).fileURL, try #require(b).fileURL]
        let hashes = try inputs.map(ImageInputProcessor.sha256(of:))

        let (edited, _) = try await run(engine, request(
            .referenceEdit, inputs: inputs, prompt: "the mug from image 1 standing in the field from image 2",
            width: 640, height: 512))
        let out = try #require(edited)
        #expect(pixelSize(out.fileURL)! == (640, 512))
        #expect(out.metadata.inputs.map(\.sha256) == hashes)
        #expect(try inputs.map(ImageInputProcessor.sha256(of:)) == hashes)
        #expect(!inputs.contains(out.fileURL))
    }

    @Test func imageToImageWithStrength() async throws {
        let engine = try await SharedEngine.shared.get()
        let (src, _) = try await run(engine, request(.textToImage, prompt: "a small house in a meadow", seed: 21))
        let (out, steps) = try await run(engine, request(
            .imageToImage(strength: 0.5), inputs: [try #require(src).fileURL], prompt: "same house in winter, snow"))
        #expect(out != nil)
        // strength 0.5 skips half of the 4-step schedule.
        #expect(steps.last == 2)
    }

    @Test func cancellationStopsBetweenStepsAndEngineStaysUsable() async throws {
        let engine = try await SharedEngine.shared.get()
        let r = request(.textToImage, prompt: "a lighthouse in a storm", width: 768, height: 768)
        await #expect(throws: GenerationError.cancelled) {
            _ = try await run(engine, r, cancelAfterStep: 1)
        }
        let stats = await engine.lastRunStats
        #expect(stats?.outcome == "cancelled")
        #expect((stats?.stepsReported ?? 4) < 4)
        let (after, _) = try await run(engine, request(.textToImage, prompt: "a lighthouse at noon"))
        #expect(after != nil)
    }

    @Test func droppingTheStreamCancelsGPUWork() async throws {
        let engine = try await SharedEngine.shared.get()
        let r = request(.textToImage, prompt: "a mountain lake", width: 768, height: 768)
        let consumer = Task {
            for try await event in try await engine.generate(request: r) {
                if case .step(1, _) = event { break }  // abandon iteration → onTermination
            }
        }
        _ = try await consumer.value
        // The engine must reach its safe point and become idle again.
        var idle = false
        for _ in 0..<600 {
            if let s = await engine.lastRunStats, s.requestID == r.id { idle = true; break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(idle)
        #expect(await engine.lastRunStats?.outcome == "cancelled")
    }

    @Test func unloadReleasesModel() async throws {
        let engine = try await SharedEngine.shared.get()
        await engine.unloadModel()
        #expect(await engine.loadedModelID() == nil)
        let report = try #require(await engine.lastUnloadReport)
        #expect(report.gpuActiveAfterGB < report.gpuActiveBeforeGB)
        try await engine.loadModel(id: "flux2-klein-4b")
        #expect(await engine.loadedModelID() == "flux2-klein-4b")
    }
}

enum LoRAFixture {
    static let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("NativeImageStudio/LoRA/flux-background-remove-lora.safetensors")
    static var present: Bool { FileManager.default.fileExists(atPath: url.path) }
}

/// Etap 4 cases live in the same serialized suite: they share one engine with the
/// unload test, so they must not run in parallel with it.
extension MLXEngineIntegrationTests {
    @Test func inpaintingKeepsPixelsOutsideMask() async throws {
        let engine = try await SharedEngine.shared.get()
        let (src, _) = try await run(engine, request(.textToImage, prompt: "a plain grey wall with a framed picture", seed: 31))
        let source = try #require(src).fileURL
        // Mask: right half white (regenerate), left half black (keep).
        let ctx = CGContext(data: nil, width: 512, height: 512, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.setFillColor(gray: 0, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: 512, height: 512))
        ctx.setFillColor(gray: 1, alpha: 1); ctx.fill(CGRect(x: 256, y: 0, width: 256, height: 512))
        let maskURL = FileManager.default.temporaryDirectory.appendingPathComponent("nis-mask-\(UUID().uuidString.prefix(6)).png")
        try FixtureFactory.write(ctx.makeImage()!, to: maskURL, type: .png)

        let mask = InputImage(sourceURL: maskURL, role: .mask)
        let (out, _) = try await run(engine, request(.inpainting(mask: mask), inputs: [source], prompt: "a bright red door"))
        let result = try #require(out)
        let before = try ImageInputProcessor().loadNormalized(source)
        let after = try ImageInputProcessor().loadNormalized(result.fileURL)
        #expect(after.width == 512 && after.height == 512)
        // Left (kept) side identical within tolerance; right side changed.
        let l0 = FixtureFactory.pixel(before, x: 60, y: 256), l1 = FixtureFactory.pixel(after, x: 60, y: 256)
        let dr: Int = abs(l0.r - l1.r)
        let dg: Int = abs(l0.g - l1.g)
        let db: Int = abs(l0.b - l1.b)
        #expect(dr + dg + db <= 6)
        #expect(result.metadata.inputs.contains { $0.role == .mask })
    }

    @Test(.enabled(if: LoRAFixture.present, "SKIPPED: test LoRA not downloaded (fal/flux-2-klein-4B-background-remove-lora)"))
    func loraIsAppliedAndRemovable() async throws {
        let engine = try await SharedEngine.shared.get()
        let lora = LoRAReference(fileURL: LoRAFixture.url, scale: 1)
        let r = GenerationRequest(modelID: "flux2-klein-4b", mode: .textToImage, prompt: "a cup of coffee on a table",
                                  width: 512, height: 512, steps: 4, guidance: 1, seed: 7, loras: [lora])
        let (withLoRA, _) = try await run(engine, r)
        let (without, _) = try await run(engine, r.with(id: UUID()).withoutLoRAs())
        let a = try ImageInputProcessor.sha256(of: try #require(withLoRA).fileURL)
        let b = try ImageInputProcessor.sha256(of: try #require(without).fileURL)
        #expect(a != b)  // the adapter changed the output for the same seed
    }
}

extension GenerationRequest {
    func withoutLoRAs() -> GenerationRequest {
        GenerationRequest(id: id, modelID: modelID, mode: mode, inputImages: inputImages, prompt: prompt,
                          negativePrompt: negativePrompt, width: width, height: height, steps: steps,
                          guidance: guidance, seed: seed, batchID: batchID, resizeMode: resizeMode, loras: [])
    }
}

enum ZImageFixture {
    static var installed: Bool {
        ModelRepository.bundledManifests().first { $0.id == "cyberrealistic-zimage-turbo" }
            .map { ZImageAdapter(descriptor: $0).isInstalled() } ?? false
    }
}

/// Separate suite (own engine) run on its own by scripts/integration-tests.sh: two MLX
/// models loaded at once would not fit in 24 GB.
@Suite("Z-Image integration (CyberRealistic Z-Image Turbo)", .serialized,
       .enabled(if: IntegrationGate.requested && ZImageFixture.installed,
                "SKIPPED: needs scripts/integration-tests.sh and Z-Image weights (scripts/download-zimage.sh)"))
struct ZImageIntegrationTests {
    @Test func zImageTextToImageAndCancel() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("NISZImage-\(UUID().uuidString.prefix(6))")
        let engine = MLXGenerationEngine(models: ModelRepository(), images: ImageRepository(outputDirectory: dir))
        try await engine.loadModel(id: "cyberrealistic-zimage-turbo")
        func req(_ steps: Int, seed: UInt64) -> GenerationRequest {
            GenerationRequest(modelID: "cyberrealistic-zimage-turbo", mode: .textToImage, prompt: "a red apple on a wooden table, photo",
                              width: 512, height: 512, steps: steps, guidance: 0, seed: seed)
        }
        let (image, steps) = try await run(engine, req(8, seed: 5))
        let out = try #require(image)
        #expect(pixelSize(out.fileURL)! == (512, 512))
        #expect(steps.last == 8)
        await #expect(throws: GenerationError.cancelled) {
            _ = try await run(engine, req(8, seed: 6), cancelAfterStep: 2)
        }
        #expect((await engine.lastRunStats?.stepsReported ?? 8) < 8)
        await engine.unloadModel()
    }
}
