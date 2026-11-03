import Application
import Domain
import Foundation
import Infrastructure
import Observation
import UniformTypeIdentifiers

/// The three user-facing edit modes. Which ones are offered depends on the model.
public enum EditMode: String, CaseIterable, Identifiable, Sendable {
    /// One image + prompt + strength.
    case transform
    /// 1…N reference images + instruction → one image.
    case references
    /// Same prompt/settings applied to each photo separately.
    case batch
    /// Repaint a masked region of one photo.
    case inpainting

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .transform: "Transformacja"
        case .references: "Referencje"
        case .batch: "Partia"
        case .inpainting: "Inpainting"
        }
    }

    /// Engine mode a single job of this edit mode uses.
    func generationMode(strength: Float, caps: EngineCapabilities) -> GenerationMode? {
        switch self {
        case .transform:
            caps.supports(.imageToImage) ? .imageToImage(strength: strength) : nil
        case .references:
            caps.supports(.referenceEdit) ? .referenceEdit : nil
        case .batch:
            caps.supports(.imageToImage) ? .imageToImage(strength: strength)
                : caps.supports(.referenceEdit) ? .referenceEdit : nil
        case .inpainting:
            // The mask URL is attached when the request is built.
            caps.supports(.inpainting) ? .inpainting(mask: InputImage(sourceURL: URL(fileURLWithPath: "/"), role: .mask)) : nil
        }
    }
}

/// One input photo shown in the strip as "obraz N".
public struct EditInput: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let url: URL
    public let size: PixelSize

    public init(id: UUID = UUID(), url: URL, size: PixelSize) {
        self.id = id
        self.url = url
        self.size = size
    }
}

@MainActor
@Observable
public final class ImageEditingViewModel {
    public private(set) var inputs: [EditInput] = [] {
        // A mask belongs to a specific photo: drop it when "obraz 1" changes.
        didSet { if inputs.first?.id != oldValue.first?.id { maskStrokes.removeAll() } }
    }
    public var prompt = ""
    public var mode: EditMode = .references {
        didSet { if mode == .inpainting && oldValue != .inpainting { lastJobID = nil } }
    }
    public var strength: Float = 0.6
    public var aspect: AspectPreset = .firstInput
    public var resizeMode: ResizeMode = .crop
    public var resolution = 1024
    public var steps = 4
    public var guidance: Float = 1
    public var seed: UInt64 = 42
    public var randomizeSeed = true
    public var errorMessage: String?
    public private(set) var rejectedFiles: [String] = []
    public private(set) var lastJobID: UUID?
    public private(set) var lastBatchID: UUID?
    public var maskStrokes: [MaskStroke] = []
    public var loras: [LoRAReference] = []
    /// Where rendered masks are written (never next to the user's photos).
    public var maskDirectory: URL = MaskRenderer.defaultDirectory

    private let services: AppServices
    private let catalog: ModelCatalogStore

    public init(services: AppServices, catalog: ModelCatalogStore) {
        self.services = services
        self.catalog = catalog
    }

    public var capabilities: EngineCapabilities? { catalog.selectedCapabilities }

    /// Modes the selected model can actually run.
    public var availableModes: [EditMode] {
        guard let caps = capabilities else { return [] }
        return EditMode.allCases.filter { $0.generationMode(strength: strength, caps: caps) != nil }
    }

    /// Max images usable in the current mode (nil = unlimited, batch).
    public var maxInputs: Int? {
        switch mode {
        case .transform, .inpainting: 1
        case .references: capabilities?.maxReferenceImages ?? 1
        case .batch: nil
        }
    }

    // MARK: Inputs

    public static let acceptedTypes: [UTType] = ImageInputProcessor.supportedTypes

    /// Adds image files (drag & drop or open panel). Decoding headers happens off the main actor.
    public func addFiles(_ urls: [URL]) async {
        let processor = ImageInputProcessor()
        let results = await Task.detached(priority: .userInitiated) { () -> [(URL, PixelSize?)] in
            urls.map { url in
                guard let type = try? processor.uniformType(of: url),
                      ImageInputProcessor.supportedTypes.contains(where: { type.conforms(to: $0) }) else { return (url, nil) }
                return (url, try? processor.orientedSize(of: url))
            }
        }.value
        var rejected: [String] = []
        for (url, size) in results {
            guard let size else { rejected.append(url.lastPathComponent); continue }
            guard !inputs.contains(where: { $0.url == url }) else { continue }
            inputs.append(EditInput(url: url, size: size))
        }
        rejectedFiles = rejected
    }

    public func remove(_ id: UUID) {
        inputs.removeAll { $0.id == id }
    }

    public func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.map { inputs[$0] }
        var remaining = inputs.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        let insertAt = destination - source.filter { $0 < destination }.count
        remaining.insert(contentsOf: moving, at: max(0, min(insertAt, remaining.count)))
        inputs = remaining
    }

    /// Moves the input with `id` one position left (-1) or right (+1).
    public func shift(_ id: UUID, by offset: Int) {
        guard let i = inputs.firstIndex(where: { $0.id == id }) else { return }
        let j = i + offset
        guard inputs.indices.contains(j) else { return }
        inputs.swapAt(i, j)
    }

    public func clear() {
        inputs.removeAll()
    }

    /// "obraz 1", "obraz 2"… label used in prompts.
    public func number(of id: UUID) -> Int? {
        inputs.firstIndex { $0.id == id }.map { $0 + 1 }
    }

    // MARK: Sizing

    func outputSize(for first: PixelSize?) -> PixelSize {
        let caps = capabilities
        let ratio = aspect.ratio ?? first?.aspectRatio ?? 1
        return ImageInputProcessor.targetSize(
            aspectRatio: ratio, targetEdge: resolution,
            multiple: caps?.dimensionMultiple ?? 32,
            minDimension: caps?.minDimension ?? 256,
            maxDimension: caps?.maxDimension ?? 2048)
    }

    public var outputSize: PixelSize { outputSize(for: inputs.first?.size) }

    // MARK: Validation

    public var problem: String? {
        guard let entry = catalog.selected else { return "Brak modeli." }
        if !entry.installed { return "Model \(entry.descriptor.name) nie jest pobrany." }
        guard availableModes.contains(mode) else { return "Model \(entry.descriptor.name) nie obsługuje trybu „\(mode.label)”." }
        if inputs.isEmpty { return "Dodaj co najmniej jedno zdjęcie." }
        if let max = maxInputs, inputs.count > max {
            return mode == .transform || mode == .inpainting
                ? "\(mode.label) używa jednego zdjęcia — usuń pozostałe lub wybierz tryb Partia."
                : "Model obsługuje maksymalnie \(max) obrazy referencyjne (dodano \(inputs.count))."
        }
        if mode == .inpainting && maskStrokes.filter({ !$0.erase }).isEmpty { return "Zamaluj obszar do zmiany na zdjęciu." }
        if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Opisz oczekiwany efekt." }
        return nil
    }

    public var canRun: Bool { problem == nil }

    // MARK: Submission

    private func nextSeed() -> UInt64 {
        randomizeSeed ? UInt64.random(in: 0...UInt64(UInt32.max)) : seed
    }

    /// Request for transform / references (the batch template uses the same shape).
    public func makeRequest() -> GenerationRequest? {
        guard let model = catalog.selected?.descriptor, let caps = capabilities,
              var gm = mode.generationMode(strength: strength, caps: caps) else { return nil }
        if mode == .inpainting {
            guard let maskURL = renderMask() else { return nil }
            gm = .inpainting(mask: InputImage(sourceURL: maskURL, role: .mask))
        }
        let used = mode == .references ? inputs : Array(inputs.prefix(1))
        let size = outputSize
        return GenerationRequest(
            modelID: model.id, mode: gm,
            inputImages: used.enumerated().map { InputImage(sourceURL: $1.url, role: $0 == 0 ? .primary : .reference) },
            prompt: prompt, width: size.width, height: size.height,
            steps: steps, guidance: guidance, seed: nextSeed(), resizeMode: resizeMode,
            loras: caps.supportsLoRA ? loras : [])
    }

    /// Rasterizes the strokes at the first photo's (oriented) size and writes a new PNG.
    func renderMask() -> URL? {
        guard let first = inputs.first,
              let mask = MaskRenderer.render(maskStrokes, width: first.size.width, height: first.size.height) else { return nil }
        return try? MaskRenderer.write(mask, in: maskDirectory)
    }

    /// Mask editor is shown in inpainting mode until an inpainting job was submitted.
    public var showsMaskEditor: Bool {
        mode == .inpainting && !inputs.isEmpty && lastJobID == nil
    }

    public func backToMask() {
        lastJobID = nil
    }

    // MARK: Profiles

    public func apply(_ profile: ModelProfile) {
        catalog.selectedModelID = profile.modelID
        steps = profile.steps
        guidance = profile.guidance
        resolution = profile.resolution
        resizeMode = profile.resizeMode
        loras = profile.loras
        if let s = profile.strength { strength = s }
        switch profile.workflow {
        case .transform: mode = .transform
        case .references: mode = .references
        case .batch: mode = .batch
        case .inpainting: mode = .inpainting
        case .textToImage: break
        }
    }

    public func makeProfile(named name: String) -> ModelProfile? {
        guard let model = catalog.selected?.descriptor else { return nil }
        let workflow: ModelProfile.Workflow = switch mode {
        case .transform: .transform
        case .references: .references
        case .batch: .batch
        case .inpainting: .inpainting
        }
        return ModelProfile(
            name: name, modelID: model.id, workflow: workflow, steps: steps, guidance: guidance,
            resolution: resolution, strength: mode == .references ? nil : strength,
            resizeMode: resizeMode, loras: loras)
    }

    public func run() async {
        errorMessage = nil
        guard canRun, let request = makeRequest() else {
            errorMessage = problem
            return
        }
        if mode == .batch {
            let sizes = Dictionary(uniqueKeysWithValues: inputs.map { ($0.url, outputSize(for: $0.size)) })
            let batchID = await services.batches.submitBatch(
                template: request, inputs: inputs.map(\.url)
            ) { url in
                sizes[url].map { (width: $0.width, height: $0.height) }
            }
            lastBatchID = batchID
            lastJobID = nil
            let failures = await services.batches.failures(batchID)
            if !failures.isEmpty {
                errorMessage = failures.map { "\($0.fileURL.lastPathComponent): \($0.message)" }.joined(separator: "\n")
            }
        } else {
            do {
                lastJobID = try await services.coordinator.submit(request)
                lastBatchID = nil
            } catch {
                errorMessage = userMessage(error)
            }
        }
    }

    public func cancelBatch(jobs: JobsStore) {
        if let lastBatchID { jobs.cancelBatch(lastBatchID) }
    }

    public func applyDefaults() {
        guard let d = catalog.selected?.descriptor else { return }
        steps = d.defaultSteps
        guidance = d.defaultGuidance
        resolution = d.preferredResolution
        if !availableModes.contains(mode), let first = availableModes.first { mode = first }
    }
}
