import Domain
import Foundation
import Testing

/// Probe that treats listed URLs as existing/readable without touching the disk.
struct FakeProbe: ImageFileProbe {
    var existing: Set<URL> = []
    var readable: Set<URL> = []
    func exists(_ url: URL) -> Bool { existing.contains(url) }
    func isReadableImage(_ url: URL) -> Bool { readable.contains(url) }
}

let caps = EngineCapabilities(
    supportedModes: [.textToImage, .imageToImage, .referenceEdit],
    maxReferenceImages: 3,
    supportedResolutions: [512, 1024],
    dimensionMultiple: 32,
    minDimension: 256,
    maxDimension: 2048,
    maxSteps: 50,
    supportsLoRA: false,
    supportsNegativePrompt: false,
    cancellation: .perStep
)

func url(_ name: String) -> URL { URL(fileURLWithPath: "/tmp/\(name).png") }

func okProbe(_ names: [String]) -> FakeProbe {
    let urls = Set(names.map(url))
    return FakeProbe(existing: urls, readable: urls)
}

func makeRequest(
    mode: GenerationMode = .textToImage,
    images: [String] = [],
    prompt: String = "a lighthouse",
    negative: String? = nil,
    width: Int = 1024,
    height: Int = 1024,
    steps: Int = 4,
    guidance: Float = 1
) -> GenerationRequest {
    GenerationRequest(
        modelID: "m", mode: mode,
        inputImages: images.enumerated().map { InputImage(sourceURL: url($1), role: $0 == 0 ? .primary : .reference) },
        prompt: prompt, negativePrompt: negative, width: width, height: height,
        steps: steps, guidance: guidance, seed: 1)
}

@Suite("Request validation")
struct RequestValidatorTests {
    @Test func validTextToImage() throws {
        try RequestValidator(probe: FakeProbe()).validate(makeRequest(), capabilities: caps)
    }

    @Test func unsupportedModeIsRejected() {
        var limited = caps
        limited.supportedModes = [.textToImage]
        #expect(throws: RequestValidationError.unsupportedMode(.referenceEdit, modelID: "m")) {
            try RequestValidator(probe: okProbe(["a"])).validate(makeRequest(mode: .referenceEdit, images: ["a"]), capabilities: limited)
        }
    }

    @Test func inpaintingRejectedWhenNotDeclared() {
        let mask = InputImage(sourceURL: url("mask"), role: .mask)
        #expect(throws: RequestValidationError.unsupportedMode(.inpainting, modelID: "m")) {
            try RequestValidator(probe: okProbe(["a", "mask"])).validate(makeRequest(mode: .inpainting(mask: mask), images: ["a"]), capabilities: caps)
        }
    }

    @Test func emptyPromptIsRejected() {
        #expect(throws: RequestValidationError.emptyPrompt) {
            try RequestValidator().validate(makeRequest(prompt: "  \n"), capabilities: caps)
        }
    }

    @Test func textToImageRejectsInputs() {
        #expect(throws: RequestValidationError.unexpectedInputImages(count: 1)) {
            try RequestValidator(probe: okProbe(["a"])).validate(makeRequest(images: ["a"]), capabilities: caps)
        }
    }

    @Test(arguments: [0, 2])
    func imageToImageNeedsExactlyOneImage(count: Int) {
        let names = (0..<count).map { "i\($0)" }
        #expect(throws: RequestValidationError.wrongImageCount(mode: .imageToImage, expected: 1...1, actual: count)) {
            try RequestValidator(probe: okProbe(names)).validate(makeRequest(mode: .imageToImage(strength: 0.5), images: names), capabilities: caps)
        }
    }

    @Test(arguments: [Float(0), -0.1, 1.01, .nan])
    func strengthOutOfRange(strength: Float) {
        #expect(throws: RequestValidationError.self) {
            try RequestValidator(probe: okProbe(["a"])).validate(makeRequest(mode: .imageToImage(strength: strength), images: ["a"]), capabilities: caps)
        }
    }

    @Test(arguments: [Float(0.01), 0.5, 1.0])
    func strengthInRange(strength: Float) throws {
        try RequestValidator(probe: okProbe(["a"])).validate(makeRequest(mode: .imageToImage(strength: strength), images: ["a"]), capabilities: caps)
    }

    @Test(arguments: 1...3)
    func referenceEditAcceptsUpToMax(count: Int) throws {
        let names = (0..<count).map { "r\($0)" }
        try RequestValidator(probe: okProbe(names)).validate(makeRequest(mode: .referenceEdit, images: names), capabilities: caps)
    }

    @Test func referenceEditLimitComesFromCapabilities() {
        let names = (0..<4).map { "r\($0)" }
        #expect(throws: RequestValidationError.wrongImageCount(mode: .referenceEdit, expected: 1...3, actual: 4)) {
            try RequestValidator(probe: okProbe(names)).validate(makeRequest(mode: .referenceEdit, images: names), capabilities: caps)
        }
        var bigger = caps
        bigger.maxReferenceImages = 4
        #expect(throws: Never.self) {
            try RequestValidator(probe: okProbe(names)).validate(makeRequest(mode: .referenceEdit, images: names), capabilities: bigger)
        }
    }

    @Test func referenceEditNeedsAtLeastOne() {
        #expect(throws: RequestValidationError.wrongImageCount(mode: .referenceEdit, expected: 1...3, actual: 0)) {
            try RequestValidator().validate(makeRequest(mode: .referenceEdit), capabilities: caps)
        }
    }

    @Test func dimensionsMustBeMultiple() {
        #expect(throws: RequestValidationError.dimensionNotMultiple(width: 1000, height: 1024, multiple: 32)) {
            try RequestValidator().validate(makeRequest(width: 1000), capabilities: caps)
        }
    }

    @Test func dimensionsRange() {
        #expect(throws: RequestValidationError.dimensionOutOfRange(width: 4096, height: 1024, allowed: 256...2048)) {
            try RequestValidator().validate(makeRequest(width: 4096), capabilities: caps)
        }
    }

    @Test func stepsRange() {
        #expect(throws: RequestValidationError.stepsOutOfRange(0, allowed: 1...50)) {
            try RequestValidator().validate(makeRequest(steps: 0), capabilities: caps)
        }
        #expect(throws: RequestValidationError.stepsOutOfRange(51, allowed: 1...50)) {
            try RequestValidator().validate(makeRequest(steps: 51), capabilities: caps)
        }
    }

    @Test func stepsBelowEngineMinimumRejected() throws {
        var c = caps
        c.minSteps = 2
        #expect(throws: RequestValidationError.stepsOutOfRange(1, allowed: 2...50)) {
            try RequestValidator().validate(makeRequest(steps: 1), capabilities: c)
        }
        try RequestValidator().validate(makeRequest(steps: 2), capabilities: c)
    }

    @Test func guidanceRange() {
        #expect(throws: RequestValidationError.guidanceOutOfRange(-1)) {
            try RequestValidator().validate(makeRequest(guidance: -1), capabilities: caps)
        }
    }

    @Test func negativePromptOnlyWhenSupported() throws {
        #expect(throws: RequestValidationError.negativePromptUnsupported) {
            try RequestValidator().validate(makeRequest(negative: "blurry"), capabilities: caps)
        }
        // Blank negative prompt is ignored.
        try RequestValidator().validate(makeRequest(negative: " "), capabilities: caps)
        var withNeg = caps
        withNeg.supportsNegativePrompt = true
        try RequestValidator().validate(makeRequest(negative: "blurry"), capabilities: withNeg)
    }

    @Test func missingAndUnreadableFiles() {
        #expect(throws: RequestValidationError.imageMissing(url("a"))) {
            try RequestValidator(probe: FakeProbe()).validate(makeRequest(mode: .referenceEdit, images: ["a"]), capabilities: caps)
        }
        let existsOnly = FakeProbe(existing: [url("a")], readable: [])
        #expect(throws: RequestValidationError.imageUnreadable(url("a"))) {
            try RequestValidator(probe: existsOnly).validate(makeRequest(mode: .referenceEdit, images: ["a"]), capabilities: caps)
        }
    }

    @Test func inpaintingMaskIsValidatedAsFile() {
        var withInpaint = caps
        withInpaint.supportedModes.insert(.inpainting)
        let mask = InputImage(sourceURL: url("mask"), role: .mask)
        #expect(throws: RequestValidationError.imageMissing(url("mask"))) {
            try RequestValidator(probe: okProbe(["a"])).validate(makeRequest(mode: .inpainting(mask: mask), images: ["a"]), capabilities: withInpaint)
        }
        let wrongRole = InputImage(sourceURL: url("mask"), role: .reference)
        #expect(throws: RequestValidationError.maskRoleMismatch) {
            try RequestValidator(probe: okProbe(["a", "mask"])).validate(makeRequest(mode: .inpainting(mask: wrongRole), images: ["a"]), capabilities: withInpaint)
        }
    }

    @Test func errorMessagesArePolishAndSpecific() {
        let e = RequestValidationError.wrongImageCount(mode: .referenceEdit, expected: 1...3, actual: 5)
        #expect(e.errorDescription?.contains("1–3") == true)
        #expect(e.errorDescription?.contains("5") == true)
    }

    @Test func realProbeReadsImageHeaders() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let garbage = dir.appendingPathComponent("not-an-image.png")
        try Data("hello".utf8).write(to: garbage)
        let probe = ImageIOFileProbe()
        #expect(probe.exists(garbage))
        #expect(!probe.isReadableImage(garbage))
        #expect(!probe.exists(dir.appendingPathComponent("missing.png")))
    }
}
