import Foundation
import ImageIO

/// Why a request cannot run. Messages are user-facing (Polish UI).
public enum RequestValidationError: Error, Sendable, Equatable, LocalizedError {
    case unsupportedMode(ModeKind, modelID: String)
    case emptyPrompt
    case unexpectedInputImages(count: Int)
    case wrongImageCount(mode: ModeKind, expected: ClosedRange<Int>, actual: Int)
    case strengthOutOfRange(Float)
    case dimensionOutOfRange(width: Int, height: Int, allowed: ClosedRange<Int>)
    case dimensionNotMultiple(width: Int, height: Int, multiple: Int)
    case stepsOutOfRange(Int, allowed: ClosedRange<Int>)
    case guidanceOutOfRange(Float)
    case negativePromptUnsupported
    case loraUnsupported
    case imageMissing(URL)
    case imageUnreadable(URL)
    case maskRoleMismatch

    public var errorDescription: String? {
        switch self {
        case .unsupportedMode(let mode, let modelID):
            "Model \(modelID) nie obsługuje trybu \(mode.rawValue)."
        case .emptyPrompt:
            "Prompt jest pusty."
        case .unexpectedInputImages(let count):
            "Tryb text-to-image nie przyjmuje obrazów wejściowych (podano \(count))."
        case .wrongImageCount(let mode, let expected, let actual):
            "Tryb \(mode.rawValue) wymaga \(expected.lowerBound == expected.upperBound ? "\(expected.lowerBound)" : "\(expected.lowerBound)–\(expected.upperBound)") obrazów, podano \(actual)."
        case .strengthOutOfRange(let s):
            "Siła transformacji (strength) musi być w zakresie (0, 1], podano \(s)."
        case .dimensionOutOfRange(let w, let h, let allowed):
            "Rozdzielczość \(w)×\(h) poza zakresem \(allowed.lowerBound)–\(allowed.upperBound) px."
        case .dimensionNotMultiple(let w, let h, let m):
            "Rozdzielczość \(w)×\(h) musi być wielokrotnością \(m) px."
        case .stepsOutOfRange(let s, let allowed):
            "Liczba kroków \(s) poza zakresem \(allowed.lowerBound)–\(allowed.upperBound)."
        case .guidanceOutOfRange(let g):
            "Guidance \(g) poza zakresem 0–30."
        case .negativePromptUnsupported:
            "Ten model nie obsługuje negatywnego promptu."
        case .loraUnsupported:
            "Ten model nie obsługuje adapterów LoRA."
        case .imageMissing(let url):
            "Nie znaleziono pliku: \(url.lastPathComponent)."
        case .imageUnreadable(let url):
            "Nie można odczytać obrazu: \(url.lastPathComponent)."
        case .maskRoleMismatch:
            "Maska musi mieć rolę .mask."
        }
    }
}

/// Checks whether a file exists and decodes as an image.
public protocol ImageFileProbe: Sendable {
    func exists(_ url: URL) -> Bool
    func isReadableImage(_ url: URL) -> Bool
}

/// Default probe: FileManager + ImageIO header decode (no full pixel decode).
public struct ImageIOFileProbe: ImageFileProbe {
    public init() {}

    public func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    public func isReadableImage(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return false }
        return w > 0 && h > 0
    }
}

/// Validates a request against the capabilities of the target model.
public struct RequestValidator: Sendable {
    public let probe: any ImageFileProbe

    public init(probe: any ImageFileProbe = ImageIOFileProbe()) {
        self.probe = probe
    }

    /// Throws the first problem found. Cheap checks first, file I/O last.
    public func validate(_ request: GenerationRequest, capabilities caps: EngineCapabilities) throws {
        let kind = request.mode.kind
        guard caps.supports(kind) else {
            throw RequestValidationError.unsupportedMode(kind, modelID: request.modelID)
        }
        guard !request.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RequestValidationError.emptyPrompt
        }

        let count = request.inputImages.count
        switch request.mode {
        case .textToImage:
            guard count == 0 else { throw RequestValidationError.unexpectedInputImages(count: count) }
        case .imageToImage(let strength):
            guard count == 1 else {
                throw RequestValidationError.wrongImageCount(mode: kind, expected: 1...1, actual: count)
            }
            guard strength > 0, strength <= 1, strength.isFinite else {
                throw RequestValidationError.strengthOutOfRange(strength)
            }
        case .referenceEdit:
            let maxRefs = max(1, caps.maxReferenceImages)
            guard (1...maxRefs).contains(count) else {
                throw RequestValidationError.wrongImageCount(mode: kind, expected: 1...maxRefs, actual: count)
            }
        case .inpainting(let mask):
            guard count == 1 else {
                throw RequestValidationError.wrongImageCount(mode: kind, expected: 1...1, actual: count)
            }
            guard mask.role == .mask else { throw RequestValidationError.maskRoleMismatch }
        }

        let range = caps.minDimension...caps.maxDimension
        guard range.contains(request.width), range.contains(request.height) else {
            throw RequestValidationError.dimensionOutOfRange(width: request.width, height: request.height, allowed: range)
        }
        let m = max(1, caps.dimensionMultiple)
        guard request.width % m == 0, request.height % m == 0 else {
            throw RequestValidationError.dimensionNotMultiple(width: request.width, height: request.height, multiple: m)
        }
        guard caps.stepRange.contains(request.steps) else {
            throw RequestValidationError.stepsOutOfRange(request.steps, allowed: caps.stepRange)
        }
        guard request.guidance.isFinite, (0...30).contains(request.guidance) else {
            throw RequestValidationError.guidanceOutOfRange(request.guidance)
        }
        if let negative = request.negativePrompt,
           !negative.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !caps.supportsNegativePrompt {
            throw RequestValidationError.negativePromptUnsupported
        }
        if !request.loras.isEmpty && !caps.supportsLoRA {
            throw RequestValidationError.loraUnsupported
        }

        for url in request.allImageFiles {
            guard probe.exists(url) else { throw RequestValidationError.imageMissing(url) }
            guard probe.isReadableImage(url) else { throw RequestValidationError.imageUnreadable(url) }
        }
    }
}
