import Application
import CoreGraphics
import Domain
import Features
import Foundation
import Infrastructure
import TestSupport
import Testing

@Suite("Model profiles")
struct ModelProfileTests {
    @Test func incompatibilitiesFollowCapabilities() {
        var caps = MockEngine.defaultCapabilities
        let p = ModelProfile(name: "x", modelID: "m", workflow: .inpainting, steps: 60, guidance: 1, resolution: 4096,
                             negativePrompt: "blur", loras: [LoRAReference(fileURL: URL(fileURLWithPath: "/a.safetensors"))])
        let issues = p.incompatibilities(with: caps)
        #expect(issues.count == 5)  // mode, LoRA, negative, steps, resolution
        caps.supportedModes.insert(.inpainting)
        caps.supportsLoRA = true
        caps.supportsNegativePrompt = true
        caps.maxSteps = 100
        caps.maxDimension = 4096
        #expect(p.incompatibilities(with: caps).isEmpty)
    }

    @Test func storePersistsAcrossInstances() async throws {
        let dir = try FixtureFactory.temporaryDirectory()
        let url = dir.appendingPathComponent("p/profiles.json")
        let a = ProfileStore(fileURL: url)
        var p = ModelProfile(name: "Portret", modelID: "m", workflow: .textToImage, steps: 4, guidance: 1, resolution: 1024)
        try await a.save(p)
        p.steps = 6
        try await a.save(p)  // replace, not duplicate
        try await a.save(ModelProfile(name: "Album", modelID: "n", workflow: .batch, steps: 4, guidance: 1, resolution: 768))
        let b = ProfileStore(fileURL: url)
        #expect(await b.all().map(\.name) == ["Album", "Portret"])
        #expect(await b.profiles(forModel: "m").first?.steps == 6)
        try await b.delete(p.id)
        #expect(await ProfileStore(fileURL: url).all().count == 1)
    }
}

@Suite("Benchmark summary")
struct BenchmarkSummaryTests {
    func rec(_ backend: String, _ gen: Double, steps: Int = 4, note: String = "app", peak: Double = 5) -> BenchmarkRecord {
        BenchmarkRecord(model: "m", backend: backend, mode: "textToImage", inputImageCount: 0, quantization: "q",
                        width: 1024, height: 1024, steps: steps, seed: 1, coldLoadSeconds: nil, generationSeconds: gen,
                        secondsPerStep: gen / Double(steps), peakMemoryGB: peak, footprintGB: 1, note: note)
    }

    @Test func groupsOnlyEquivalentConditionsAndSkipsCancelled() {
        let rows = [rec("mlx", 10), rec("mlx", 14, peak: 7), rec("mlx", 30, steps: 8), rec("coreml", 4),
                    rec("mlx", 1, note: "cancel test; cancelled")]
        let s = BenchmarkSummary.summarize(rows)
        #expect(s.count == 3)
        let mlx4 = s.first { $0.key.backend == "mlx" && $0.key.steps == 4 }!
        #expect(mlx4.runs == 2)
        #expect(mlx4.meanGenerationSeconds == 12)
        #expect(mlx4.maxPeakMemoryGB == 7)
    }

    @Test func batchAverages() {
        let rows = [rec("mlx", 10, note: "batch:abc"), rec("mlx", 20, note: "batch:abc"), rec("mlx", 5)]
        let b = BenchmarkSummary.batchAverages(rows)
        #expect(b.count == 1 && b[0].batch == "abc" && b[0].images == 2 && b[0].meanSeconds == 15)
    }

    @Test func recorderMapsGeneratedImage() {
        let req = TestModels.request(mode: .imageToImage(strength: 0.5),
                                     inputs: [InputImage(sourceURL: URL(fileURLWithPath: "/a"), role: .primary)], batchID: UUID())
        let meta = GenerationMetadata(request: req, backend: "mlx", inputs: [.init(path: "/a", sha256: "x", role: .primary)])
        let img = GeneratedImage(fileURL: URL(fileURLWithPath: "/o.png"), seed: 42, elapsedSeconds: 9, metadata: meta,
                                 stats: RunStats(secondsPerStep: 2, peakMemoryGB: 11, peakMemorySource: "mlx", thermalState: "fair"))
        let r = BenchmarkRecorder.record(for: img, model: TestModels.descriptor())
        #expect(r.mode == "imageToImage" && r.inputImageCount == 1 && r.generationSeconds == 9)
        #expect(r.secondsPerStep == 2 && r.peakMemoryGB == 11 && r.thermalState == "fair")
        #expect(r.note?.hasPrefix("batch:") == true)
    }
}

@Suite("Mask renderer")
struct MaskRendererTests {
    @Test func paintsWhiteOnBlackInImageCoordinates() throws {
        // Horizontal stroke across the top quarter.
        let stroke = MaskStroke(points: [CGPoint(x: 0, y: 0.25), CGPoint(x: 1, y: 0.25)], width: 0.1, erase: false)
        let mask = try #require(MaskRenderer.render([stroke], width: 200, height: 100))
        #expect(mask.width == 200 && mask.height == 100)
        #expect(FixtureFactory.pixel(mask, x: 100, y: 25).r > 200)  // painted (top-left origin)
        #expect(FixtureFactory.pixel(mask, x: 100, y: 75).r < 50)   // kept
        let c = MaskRenderer.coverage(mask)
        #expect(c > 0.05 && c < 0.2)
    }

    @Test func eraserAndInversion() throws {
        let paint = MaskStroke(points: [CGPoint(x: 0.5, y: 0.5)], width: 0.5, erase: false)
        let erase = MaskStroke(points: [CGPoint(x: 0.5, y: 0.5)], width: 0.2, erase: true)
        let mask = try #require(MaskRenderer.render([paint, erase], width: 100, height: 100))
        #expect(FixtureFactory.pixel(mask, x: 50, y: 50).r < 50)   // erased center
        #expect(FixtureFactory.pixel(mask, x: 50, y: 32).r > 200)  // ring still painted
        let inverted = try #require(MaskRenderer.render([], width: 10, height: 10, inverted: true))
        #expect(MaskRenderer.coverage(inverted) == 1)
    }
}

@Suite("Etap 4 view models")
@MainActor
struct Etap4ViewModelTests {
    func caps(inpainting: Bool = true, lora: Bool = true) -> EngineCapabilities {
        var c = MockEngine.defaultCapabilities
        if inpainting { c.supportedModes.insert(.inpainting) }
        c.supportsLoRA = lora
        return c
    }

    @Test func inpaintingNeedsMaskAndBuildsMaskFile() async throws {
        let rig = try await FeatureRig(capabilities: caps())
        let vm = ImageEditingViewModel(services: rig.services, catalog: rig.catalog)
        vm.maskDirectory = rig.dir.appendingPathComponent("masks")
        #expect(vm.availableModes.contains(.inpainting))
        vm.mode = .inpainting
        vm.prompt = "a red scarf"
        await vm.addFiles([try rig.photo("p", width: 300, height: 200)])
        #expect(vm.problem == "Zamaluj obszar do zmiany na zdjęciu.")
        #expect(vm.showsMaskEditor)
        vm.maskStrokes = [MaskStroke(points: [CGPoint(x: 0.5, y: 0.5)], width: 0.2, erase: false)]
        #expect(vm.canRun)
        let request = try #require(vm.makeRequest())
        guard case .inpainting(let mask) = request.mode else { Issue.record("expected inpainting"); return }
        #expect(mask.role == .mask)
        let size = try ImageInputProcessor().orientedSize(of: mask.sourceURL)
        #expect(size == PixelSize(width: 300, height: 200))
        #expect(mask.sourceURL.deletingLastPathComponent().standardizedFileURL.path == vm.maskDirectory.standardizedFileURL.path)
        // Validator accepts it (mask exists and is readable).
        try RequestValidator().validate(request, capabilities: caps())
    }

    @Test func changingPrimaryPhotoClearsMask() async throws {
        let rig = try await FeatureRig(capabilities: caps())
        let vm = ImageEditingViewModel(services: rig.services, catalog: rig.catalog)
        vm.mode = .inpainting
        await vm.addFiles([try rig.photo("a"), try rig.photo("b")])
        vm.maskStrokes = [MaskStroke(points: [.zero], width: 0.1, erase: false)]
        vm.shift(vm.inputs[1].id, by: -1)
        #expect(vm.maskStrokes.isEmpty)
    }

    @Test func lorasOnlySentWhenSupported() async throws {
        let lora = LoRAReference(fileURL: URL(fileURLWithPath: "/x.safetensors"), scale: 0.8)
        let with = try await FeatureRig(capabilities: caps(lora: true))
        let g1 = GenerationViewModel(services: with.services, catalog: with.catalog)
        g1.prompt = "x"
        g1.loras = [lora]
        #expect(g1.makeRequests().first?.loras == [lora])
        let without = try await FeatureRig(capabilities: caps(lora: false))
        let g2 = GenerationViewModel(services: without.services, catalog: without.catalog)
        g2.prompt = "x"
        g2.loras = [lora]
        #expect(g2.makeRequests().first?.loras == [])
    }

    @Test func profileRoundTripThroughViewModels() async throws {
        let rig = try await FeatureRig(capabilities: caps())
        let edit = ImageEditingViewModel(services: rig.services, catalog: rig.catalog)
        edit.mode = .transform
        edit.strength = 0.35
        edit.steps = 7
        edit.resizeMode = .pad
        let profile = try #require(edit.makeProfile(named: "Film"))
        #expect(profile.workflow == .transform && profile.strength == 0.35)

        let other = ImageEditingViewModel(services: rig.services, catalog: rig.catalog)
        other.apply(profile)
        #expect(other.mode == .transform && other.strength == 0.35 && other.steps == 7 && other.resizeMode == .pad)

        let gen = GenerationViewModel(services: rig.services, catalog: rig.catalog)
        gen.prompt = "fox"
        gen.apply(ModelProfile(name: "p", modelID: "test-model", workflow: .textToImage, steps: 9, guidance: 2,
                               resolution: 768, promptPrefix: "cinematic photo,"))
        #expect(gen.steps == 9 && gen.resolution == 768 && gen.prompt == "cinematic photo, fox")
    }
}

@Suite("Fit geometry (before/after, mask editor)")
struct FitGeometryTests {
    @Test func portraitImageInWideContainerIsCenteredHorizontally() {
        let r = FitGeometry.fittedRect(aspect: 0.5, in: CGSize(width: 800, height: 400))
        #expect(r == CGRect(x: 300, y: 0, width: 200, height: 400))
        // The divider at the image's middle maps to 50 %, not to the container's 50 %.
        #expect(FitGeometry.fraction(ofX: 400, in: r) == 0.5)
        #expect(FitGeometry.fraction(ofX: 100, in: r) == 0)   // left margin clamps to "all before"
        #expect(FitGeometry.fraction(ofX: 700, in: r) == 1)
    }

    @Test func landscapeImageInTallContainerIsCenteredVertically() {
        let r = FitGeometry.fittedRect(aspect: 2, in: CGSize(width: 400, height: 800))
        #expect(r == CGRect(x: 0, y: 300, width: 400, height: 200))
    }

    @Test func aspectRatioHonoursExifOrientation() throws {
        let dir = try FixtureFactory.temporaryDirectory()
        let url = try FixtureFactory.write(FixtureFactory.quadrantImage(width: 300, height: 100),
                                           to: dir.appendingPathComponent("o.jpg"), type: .jpeg, orientation: 6)
        #expect(abs((FitGeometry.aspectRatio(of: url) ?? 0) - 1.0 / 3.0) < 0.001)
    }
}
