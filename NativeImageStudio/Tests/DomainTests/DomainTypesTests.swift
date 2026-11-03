import Domain
import Foundation
import Testing

@Suite("Domain types")
struct DomainTypesTests {
    @Test func modeKinds() {
        #expect(GenerationMode.textToImage.kind == .textToImage)
        #expect(GenerationMode.imageToImage(strength: 0.3).kind == .imageToImage)
        #expect(GenerationMode.referenceEdit.kind == .referenceEdit)
        let mask = InputImage(sourceURL: URL(fileURLWithPath: "/m.png"), role: .mask)
        #expect(GenerationMode.inpainting(mask: mask).kind == .inpainting)
        #expect(!ModeKind.textToImage.usesInputImages)
        #expect(ModeKind.referenceEdit.usesInputImages)
    }

    @Test func requestCodableRoundTrip() throws {
        let mask = InputImage(sourceURL: URL(fileURLWithPath: "/m.png"), role: .mask)
        let r = GenerationRequest(
            modelID: "x", mode: .inpainting(mask: mask),
            inputImages: [InputImage(sourceURL: URL(fileURLWithPath: "/a.png"), role: .primary)],
            prompt: "p", width: 512, height: 768, steps: 4, guidance: 1, seed: 9, batchID: UUID())
        let data = try JSONEncoder().encode(r)
        #expect(try JSONDecoder().decode(GenerationRequest.self, from: data) == r)
        #expect(r.allImageFiles.map(\.lastPathComponent) == ["a.png", "m.png"])
    }

    @Test func withCopiesSettingsAndReplacesIdentity() {
        let r = GenerationRequest(modelID: "x", mode: .imageToImage(strength: 0.4), prompt: "p",
                                  width: 512, height: 512, steps: 4, guidance: 1, seed: 1)
        let batch = UUID()
        let input = InputImage(sourceURL: URL(fileURLWithPath: "/b.png"), role: .primary)
        let c = r.with(inputImages: [input], batchID: .some(batch), width: 640)
        #expect(c.id != r.id)
        #expect(c.batchID == batch)
        #expect(c.inputImages == [input])
        #expect(c.width == 640 && c.height == 512)
        #expect(c.mode == r.mode && c.prompt == r.prompt && c.seed == r.seed)
    }

    @Test func primaryImagePrefersRole() {
        let ref = InputImage(sourceURL: URL(fileURLWithPath: "/r.png"), role: .reference)
        let prim = InputImage(sourceURL: URL(fileURLWithPath: "/p.png"), role: .primary)
        let r = GenerationRequest(modelID: "x", mode: .referenceEdit, inputImages: [ref, prim], prompt: "p",
                                  width: 512, height: 512, steps: 4, guidance: 1, seed: 1)
        #expect(r.primaryImage == prim)
    }

    @Test func jobStateTerminality() {
        #expect(!JobState.queued.isTerminal)
        #expect(!JobState.loading.isTerminal)
        #expect(!JobState.running(step: 1, total: 4).isTerminal)
        #expect(JobState.cancelled.isTerminal)
        #expect(JobState.failed("x").isTerminal)
    }

    @Test func manifestCapabilitiesMapping() throws {
        let json = """
        {"id":"flux2-klein-4b","name":"FLUX.2 Klein 4B","architecture":"flux2","backend":"mlx","quantization":"int4",
         "capabilities":["textToImage","imageToImage","referenceEdit"],"maxReferenceImages":3,"preferredResolution":1024,
         "supportedResolutions":[512,1024],"defaultSteps":4,"defaultGuidance":1.0,"minimumMemoryGB":16,
         "license":"Apache-2.0","commercialUse":true,"knownLimitations":[],"supportsLoRA":true,
         "supportsNegativePrompt":false,"backendOptions":{}}
        """
        let d = try JSONDecoder().decode(ModelDescriptor.self, from: Data(json.utf8))
        let c = d.engineCapabilities(cancellation: .perStep, dimensionMultiple: 32)
        #expect(c.supportedModes == [.textToImage, .imageToImage, .referenceEdit])
        #expect(c.maxReferenceImages == 3)
        #expect(c.dimensionMultiple == 32)
        #expect(d.memory == nil)

        var t2iOnly = d
        t2iOnly.capabilities = [.textToImage]
        #expect(t2iOnly.engineCapabilities(cancellation: .perStep).maxReferenceImages == 0)
    }

    @Test func generationErrorMessages() {
        let e = GenerationError.insufficientMemory(requiredGB: 14.2, availableGB: 9.5, detail: "Zmniejsz rozdzielczość.")
        #expect(e.errorDescription?.contains("14.2") == true)
        #expect(e.errorDescription?.contains("9.5") == true)
    }
}
