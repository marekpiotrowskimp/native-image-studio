import CoreMLEngine
import Domain
import Foundation
import Infrastructure
import Testing

/// Real Core ML inference (RealVisXL V5 Lightning). Runs via `scripts/integration-tests.sh`
/// and only when the compiled resources are installed.
enum CoreMLGate {
    static let modelID = "realvisxl-v5-lightning-coreml"

    static var installed: Bool {
        ModelRepository.bundledManifests().first { $0.id == modelID }.map { CoreMLModelLoader.isInstalled($0) } ?? false
    }

    static var enabled: Bool { IntegrationGate.requested && installed }

    static var reason: Comment {
        if !IntegrationGate.requested { return "SKIPPED: heavy Core ML inference — run scripts/integration-tests.sh" }
        return "SKIPPED: Core ML resources for \(modelID) not installed — run `nis-poc download --model \(modelID)`"
    }
}

actor SharedCoreMLEngine {
    static let shared = SharedCoreMLEngine()
    private var engine: CoreMLGenerationEngine?
    let outputDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("NISCoreMLIntegration-\(UUID().uuidString.prefix(6))")

    func get() async throws -> CoreMLGenerationEngine {
        if let engine { return engine }
        let e = CoreMLGenerationEngine(models: ModelRepository(), images: ImageRepository(outputDirectory: outputDirectory))
        try await e.loadModel(id: CoreMLGate.modelID)
        engine = e
        return e
    }
}

func runCoreML(_ engine: CoreMLGenerationEngine, _ request: GenerationRequest, cancelAfterStep: Int? = nil) async throws -> (GeneratedImage?, [Int]) {
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

func sdxlRequest(_ mode: GenerationMode, inputs: [URL] = [], prompt: String, steps: Int = 6, seed: UInt64 = 3) -> GenerationRequest {
    GenerationRequest(
        modelID: CoreMLGate.modelID, mode: mode,
        inputImages: inputs.map { InputImage(sourceURL: $0, role: .primary) },
        prompt: prompt, negativePrompt: "blurry, low quality",
        width: 1024, height: 1024, steps: steps, guidance: 2, seed: seed)
}

@Suite("Core ML engine integration (RealVisXL Lightning)", .serialized, .enabled(if: CoreMLGate.enabled, CoreMLGate.reason))
struct CoreMLEngineIntegrationTests {
    @Test func textToImage() async throws {
        let engine = try await SharedCoreMLEngine.shared.get()
        let (image, steps) = try await runCoreML(engine, sdxlRequest(.textToImage, prompt: "a red apple on a wooden table, photo"))
        let out = try #require(image)
        #expect(steps.last == steps.count && !steps.isEmpty)
        #expect(pixelSize(out.fileURL)! == (1024, 1024))
        #expect(out.metadata.backend == "coreml")
    }

    @Test func imageToImage() async throws {
        let engine = try await SharedCoreMLEngine.shared.get()
        let (src, _) = try await runCoreML(engine, sdxlRequest(.textToImage, prompt: "a small house in a meadow", seed: 21))
        let input = try #require(src).fileURL
        let hash = try ImageInputProcessor.sha256(of: input)
        let (out, _) = try await runCoreML(engine, sdxlRequest(.imageToImage(strength: 0.6), inputs: [input], prompt: "same house in winter, snow"))
        #expect(out != nil)
        #expect(try ImageInputProcessor.sha256(of: input) == hash)
    }

    @Test func cancellationStopsAtStepBoundary() async throws {
        let engine = try await SharedCoreMLEngine.shared.get()
        await #expect(throws: GenerationError.cancelled) {
            _ = try await runCoreML(engine, sdxlRequest(.textToImage, prompt: "a lighthouse", steps: 8), cancelAfterStep: 1)
        }
        let stats = await engine.lastRunStats
        #expect(stats?.outcome == "cancelled")
        #expect((stats?.stepsReported ?? 99) < 8)
        let (after, _) = try await runCoreML(engine, sdxlRequest(.textToImage, prompt: "a lighthouse at noon"))
        #expect(after != nil)
    }

    @Test func unload() async throws {
        let engine = try await SharedCoreMLEngine.shared.get()
        await engine.unloadModel()
        #expect(await engine.loadedModelID() == nil)
    }
}

/// Every installed SDXL Core ML model: loads, reports its native resolution and generates.
enum InstalledSDXL {
    static let ids: [String] = ModelRepository.bundledManifests()
        .filter { $0.backend == .coreml && CoreMLModelLoader.isInstalled($0) }
        .map(\.id).sorted()
}

extension CoreMLEngineIntegrationTests {
    @Test(arguments: InstalledSDXL.ids)
    func everyInstalledSDXLModelGenerates(modelID: String) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("NISSDXL-\(UUID().uuidString.prefix(6))")
        let engine = CoreMLGenerationEngine(models: ModelRepository(), images: ImageRepository(outputDirectory: dir))
        let caps = try #require(await engine.capabilities(forModel: modelID))
        let size = caps.maxDimension
        try await engine.loadModel(id: modelID)
        let r = GenerationRequest(modelID: modelID, mode: .textToImage, prompt: "a red apple on a wooden table, photo",
                                  width: size, height: size, steps: 3, guidance: 5, seed: 1)
        let (image, steps) = try await runCoreML(engine, r)
        let out = try #require(image)
        #expect(pixelSize(out.fileURL)! == (size, size))
        #expect(!steps.isEmpty)
        await engine.unloadModel()
    }
}
