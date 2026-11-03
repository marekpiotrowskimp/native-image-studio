import CoreMLEngine
import MLXEngine
import StableDiffusion
import Domain
import Foundation
import Infrastructure
import TestSupport
import Testing

@Suite("Core ML engine (no inference)")
struct CoreMLEngineTests {
    func descriptor(resourcePath: String? = nil, modes: [ModeKind] = [.textToImage, .imageToImage]) -> ModelDescriptor {
        var d = TestModels.descriptor(id: "sdxl-test", backend: .coreml, capabilities: modes, maxReferenceImages: 0)
        d.architecture = "sdxl"
        if let resourcePath { d.backendOptions["resourcePath"] = resourcePath }
        return d
    }

    @Test func installationRequiresCompiledResources() throws {
        let dir = try FixtureFactory.temporaryDirectory()
        let d = descriptor(resourcePath: dir.path)
        #expect(!CoreMLModelLoader.isInstalled(d))
        for name in ["TextEncoder2.mlmodelc", "VAEDecoder.mlmodelc", "UnetChunk1.mlmodelc"] {
            try FileManager.default.createDirectory(at: dir.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        #expect(!CoreMLModelLoader.isInstalled(d))  // tokenizer files missing
        for name in ["vocab.json", "merges.txt"] { try Data("{}".utf8).write(to: dir.appendingPathComponent(name)) }
        #expect(CoreMLModelLoader.isInstalled(d))
        #expect(!CoreMLModelLoader.hasEncoder(d))
    }

    @Test func capabilitiesDropImageToImageWithoutEncoder() async throws {
        let dir = try FixtureFactory.temporaryDirectory()
        for name in ["TextEncoder2.mlmodelc", "VAEDecoder.mlmodelc", "Unet.mlmodelc"] {
            try FileManager.default.createDirectory(at: dir.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        for name in ["vocab.json", "merges.txt"] { try Data("{}".utf8).write(to: dir.appendingPathComponent(name)) }
        let models = ModelRepository(builtIn: [descriptor(resourcePath: dir.path)])
        let engine = CoreMLGenerationEngine(models: models, images: ImageRepository(outputDirectory: dir.appendingPathComponent("out")))
        let caps = try #require(await engine.capabilities(forModel: "sdxl-test"))
        #expect(caps.supportedModes == [.textToImage])
        #expect(caps.maxReferenceImages == 0)
        // No UNet metadata in the fake install → manifest's preferred resolution.
        #expect(caps.minDimension == 512 && caps.maxDimension == 512)
        #expect(caps.supportsNegativePrompt)
        // 1 step crashes Apple's DPM-Solver++ with Karras spacing (NaN → Int).
        #expect(caps.minSteps == 2)
        #expect(await engine.isInstalled(modelID: "sdxl-test"))

        try FileManager.default.createDirectory(at: dir.appendingPathComponent("VAEEncoder.mlmodelc"), withIntermediateDirectories: true)
        #expect(await engine.capabilities(forModel: "sdxl-test")?.supportedModes == [.textToImage, .imageToImage])
    }

    @Test func nativeResolutionComesFromUNetMetadata() throws {
        let dir = try FixtureFactory.temporaryDirectory()
        let unet = dir.appendingPathComponent("UnetChunk1.mlmodelc")
        try FileManager.default.createDirectory(at: unet, withIntermediateDirectories: true)
        let meta = #"[{"inputSchema":[{"name":"sample","shape":"[2, 4, 96, 96]"},{"name":"timestep","shape":"[2]"}]}]"#
        try Data(meta.utf8).write(to: unet.appendingPathComponent("metadata.json"))
        let d = descriptor(resourcePath: dir.path)
        #expect(CoreMLModelLoader.nativeResolution(d) == 768)
        #expect(CoreMLModelLoader.nativeResolution(descriptor(resourcePath: dir.appendingPathComponent("none").path)) == nil)
    }

    @Test func newSDXLManifestsMatchVerifiedPackages() async throws {
        let repo = ModelRepository()
        let rv = try await repo.descriptor(id: "realvisxl-v5-coreml")
        #expect(rv.preferredResolution == 768 && rv.capabilities == [.textToImage])
        let jg = try await repo.descriptor(id: "juggernaut-xl-v9-coreml")
        #expect(jg.capabilities == [.textToImage] && jg.defaultSteps == 35)
        let cx = try await repo.descriptor(id: "cyberrealistic-xl-v10-coreml")
        #expect(Set(cx.capabilities) == [.textToImage, .imageToImage] && cx.defaultGuidance == 7.5)
        let zi = try await repo.descriptor(id: "zimage-turbo")
        #expect(zi.architecture == "zimage" && zi.backendOptions["transformerURL"]?.contains("Comfy-Org") == true)
        // Pony conversion ships no VAEEncoder; WAI ships one (img2img).
        let pony = try await repo.descriptor(id: "pony-diffusion-v6-xl-coreml")
        #expect(pony.capabilities == [.textToImage] && !pony.compilesForNeuralEngine)
        let wai = try await repo.descriptor(id: "wai-illustrious-v17-coreml")
        #expect(Set(wai.capabilities) == [.textToImage, .imageToImage] && wai.defaultSteps == 25)
    }

    @Test func bundledManifestDeclaresOnlyVerifiedModes() async throws {
        let d = try await ModelRepository().descriptor(id: "realvisxl-v5-lightning-coreml")
        #expect(d.backend == .coreml && d.architecture == "sdxl")
        #expect(Set(d.capabilities) == [.textToImage, .imageToImage])
        #expect(d.maxReferenceImages == 0)
        #expect(d.backendOptions["hfRepo"] != nil)
    }

    @Test func generateWithoutLoadedModelFails() async throws {
        let dir = try FixtureFactory.temporaryDirectory()
        let engine = CoreMLGenerationEngine(models: ModelRepository(builtIn: [descriptor(resourcePath: dir.path)]),
                                            images: ImageRepository(outputDirectory: dir))
        await #expect(throws: GenerationError.modelNotLoaded) {
            _ = try await engine.generate(request: TestModels.request(model: "sdxl-test", width: 1024, height: 1024))
        }
        await #expect(throws: GenerationError.self) { try await engine.loadModel(id: "sdxl-test") }
        #expect(await engine.loadedModelID() == nil)
    }
}

@Suite("BPE tokenizer (vendored, patched)")
struct BPETokenizerTests {
    @Test func crlfMergesFileStillMerges() throws {
        let dir = try FixtureFactory.temporaryDirectory()
        let merges = dir.appendingPathComponent("merges.txt")
        let vocab = dir.appendingPathComponent("vocab.json")
        try Data("#version: 0.2\r\nt h\r\nth e</w>\r\n".utf8).write(to: merges)
        let v: [String: Int] = ["t": 0, "h": 1, "e</w>": 2, "th": 3, "the</w>": 4, "<|startoftext|>": 5, "<|endoftext|>": 6]
        try JSONEncoder().encode(v).write(to: vocab)
        let tokenizer = try BPETokenizer(mergesAt: merges, vocabularyAt: vocab)
        let (tokens, ids) = tokenizer.tokenize(input: "the")
        #expect(tokens == ["<|startoftext|>", "the</w>", "<|endoftext|>"])
        #expect(ids == [5, 4, 6])
    }
}

@Suite("Model management")
struct ModelManagementTests {
    @Test func userManagedResourcesAreNeverDeleted() async throws {
        let dir = try FixtureFactory.temporaryDirectory()
        for name in ["TextEncoder2.mlmodelc", "VAEDecoder.mlmodelc", "Unet.mlmodelc"] {
            try FileManager.default.createDirectory(at: dir.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        for name in ["vocab.json", "merges.txt"] { try Data("{}".utf8).write(to: dir.appendingPathComponent(name)) }
        var d = TestModels.descriptor(id: "sdxl-user", backend: .coreml, capabilities: [.textToImage], maxReferenceImages: 0)
        d.architecture = "sdxl"
        d.backendOptions["resourcePath"] = dir.path
        let engine = CoreMLGenerationEngine(models: ModelRepository(builtIn: [d]), images: ImageRepository(outputDirectory: dir.appendingPathComponent("out")))
        #expect(await engine.installedSizeBytes(modelID: "sdxl-user") > 0)
        await #expect(throws: GenerationError.self) { _ = try await engine.remove(modelID: "sdxl-user") }
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Unet.mlmodelc").path))
    }

    @Test func diskUsageCountsNestedFiles() throws {
        let dir = try FixtureFactory.temporaryDirectory()
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("a/b"), withIntermediateDirectories: true)
        try Data(count: 10_000).write(to: dir.appendingPathComponent("a/b/x.bin"))
        try Data(count: 5_000).write(to: dir.appendingPathComponent("y.bin"))
        #expect(diskUsage(of: dir) >= 15_000)
        #expect(diskUsage(of: dir.appendingPathComponent("missing")) == 0)
    }
}

@Suite("Z-Image checkpoint conversion")
struct ZImageCheckpointTests {
    @Test func comfyKeysMapToPortLayout() {
        let input: [String: String] = [
            "model.diffusion_model.layers.0.attention.qkv.weight": "QKV0",
            "model.diffusion_model.layers.0.attention.out.weight": "O",
            "model.diffusion_model.layers.0.attention.q_norm.weight": "QN",
            "model.diffusion_model.layers.0.attention.k_norm.weight": "KN",
            "model.diffusion_model.noise_refiner.1.attention.qkv.weight": "QKV1",
            "model.diffusion_model.final_layer.adaLN_modulation.1.weight": "F",
            "model.diffusion_model.final_layer.linear.bias": "L",
            "model.diffusion_model.t_embedder.mlp.0.weight": "T0",
            "model.diffusion_model.t_embedder.mlp.2.bias": "T2",
            "model.diffusion_model.cap_embedder.0.weight": "C0",
            "model.diffusion_model.cap_embedder.1.bias": "C1",
            "model.diffusion_model.x_embedder.weight": "X",
            "model.diffusion_model.layers.0.feed_forward.w1.weight": "W1",
        ]
        let out = ZImageCheckpoint.remap(input) { ($0 + ".q", $0 + ".k", $0 + ".v") }
        #expect(out["layers.0.attention.to_q.weight"] == "QKV0.q")
        #expect(out["layers.0.attention.to_k.weight"] == "QKV0.k")
        #expect(out["layers.0.attention.to_v.weight"] == "QKV0.v")
        #expect(out["noise_refiner.1.attention.to_v.weight"] == "QKV1.v")
        #expect(out["layers.0.attention.to_out.0.weight"] == "O")
        #expect(out["layers.0.attention.norm_q.weight"] == "QN")
        #expect(out["layers.0.attention.norm_k.weight"] == "KN")
        #expect(out["final_layer.adaLN_linear.weight"] == "F")
        #expect(out["final_layer.linear.bias"] == "L")
        #expect(out["t_embedder.mlp_in.weight"] == "T0")
        #expect(out["t_embedder.mlp_out.bias"] == "T2")
        #expect(out["cap_embedder_norm.weight"] == "C0")
        #expect(out["cap_embedder_linear.bias"] == "C1")
        #expect(out["x_embedder.weight"] == "X")
        #expect(out["layers.0.feed_forward.w1.weight"] == "W1")
        #expect(out.count == input.count + 4)  // two fused qkv → three tensors each
    }

    @Test func manifestDeclaresOnlyZImageModes() async throws {
        let d = try await ModelRepository().descriptor(id: "cyberrealistic-zimage-turbo")
        #expect(d.architecture == "zimage" && d.backend == .mlx)
        #expect(Set(d.capabilities) == [.textToImage, .imageToImage])
        #expect(!d.supportsNegativePrompt && !d.supportsLoRA)
        #expect(d.defaultSteps == 8 && d.defaultGuidance == 0)
    }
}
