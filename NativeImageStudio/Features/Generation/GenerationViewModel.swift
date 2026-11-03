import Application
import Domain
import Foundation
import Infrastructure
import Observation

/// Output aspect ratio choices.
public enum AspectPreset: String, CaseIterable, Identifiable, Sendable {
    case firstInput, square, landscape3x2, portrait2x3, wide16x9, tall9x16

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .firstInput: "Jak obraz 1"
        case .square: "1:1"
        case .landscape3x2: "3:2"
        case .portrait2x3: "2:3"
        case .wide16x9: "16:9"
        case .tall9x16: "9:16"
        }
    }

    public var ratio: Double? {
        switch self {
        case .firstInput: nil
        case .square: 1
        case .landscape3x2: 3.0 / 2.0
        case .portrait2x3: 2.0 / 3.0
        case .wide16x9: 16.0 / 9.0
        case .tall9x16: 9.0 / 16.0
        }
    }

    public static var textToImageCases: [AspectPreset] { allCases.filter { $0 != .firstInput } }
}

@MainActor
@Observable
public final class GenerationViewModel {
    public var prompt = ""
    public var negativePrompt = ""
    public var aspect: AspectPreset = .square
    public var resolution = 1024
    public var steps = 4
    public var guidance: Float = 1
    public var seed: UInt64 = 42
    public var randomizeSeed = true
    public var count = 1
    public var loras: [LoRAReference] = []
    public private(set) var submittedJobIDs: [UUID] = []
    public var errorMessage: String?

    private let services: AppServices
    private let catalog: ModelCatalogStore

    public init(services: AppServices, catalog: ModelCatalogStore) {
        self.services = services
        self.catalog = catalog
    }

    public var capabilities: EngineCapabilities? { catalog.selectedCapabilities }

    public var outputSize: PixelSize {
        let caps = capabilities
        return ImageInputProcessor.targetSize(
            aspectRatio: aspect.ratio ?? 1,
            targetEdge: resolution,
            multiple: caps?.dimensionMultiple ?? 32,
            minDimension: caps?.minDimension ?? 256,
            maxDimension: caps?.maxDimension ?? 2048)
    }

    public var canGenerate: Bool {
        guard let entry = catalog.selected, entry.installed,
              entry.capabilities?.supports(.textToImage) == true else { return false }
        return !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Why the Generate button is disabled (shown under it).
    public var disabledReason: String? {
        guard let entry = catalog.selected else { return "Brak modeli." }
        if !entry.installed { return "Model \(entry.descriptor.name) nie jest pobrany (zakładka Modele)." }
        if entry.capabilities?.supports(.textToImage) != true { return "Wybrany model nie obsługuje generowania z tekstu." }
        if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Wpisz prompt." }
        return nil
    }

    /// Apply model defaults when the selection changes.
    public func applyDefaults() {
        guard let d = catalog.selected?.descriptor else { return }
        steps = d.defaultSteps
        guidance = d.defaultGuidance
        resolution = d.preferredResolution
        if !(capabilities?.supportsNegativePrompt ?? false) { negativePrompt = "" }
    }

    public func makeRequests() -> [GenerationRequest] {
        guard let model = catalog.selected?.descriptor else { return [] }
        let size = outputSize
        return (0..<max(1, count)).map { i in
            let s = randomizeSeed ? UInt64.random(in: 0...UInt64(UInt32.max)) : seed &+ UInt64(i)
            return GenerationRequest(
                modelID: model.id, mode: .textToImage, prompt: prompt,
                negativePrompt: negativePrompt.isEmpty ? nil : negativePrompt,
                width: size.width, height: size.height, steps: steps, guidance: guidance, seed: s,
                loras: (capabilities?.supportsLoRA ?? false) ? loras : [])
        }
    }

    // MARK: Profiles

    public func apply(_ profile: ModelProfile) {
        catalog.selectedModelID = profile.modelID
        steps = profile.steps
        guidance = profile.guidance
        resolution = profile.resolution
        negativePrompt = profile.negativePrompt ?? ""
        loras = profile.loras
        if let prefix = profile.promptPrefix, !prefix.isEmpty, !prompt.hasPrefix(prefix) {
            prompt = prefix + (prompt.isEmpty ? "" : " " + prompt)
        }
    }

    public func makeProfile(named name: String) -> ModelProfile? {
        guard let model = catalog.selected?.descriptor else { return nil }
        return ModelProfile(
            name: name, modelID: model.id, workflow: .textToImage, steps: steps, guidance: guidance,
            resolution: resolution, negativePrompt: negativePrompt.isEmpty ? nil : negativePrompt, loras: loras)
    }

    public func generate() async {
        errorMessage = nil
        for request in makeRequests() {
            do {
                let id = try await services.coordinator.submit(request)
                submittedJobIDs.append(id)
            } catch {
                errorMessage = userMessage(error)
                return
            }
        }
    }

    /// Stop: cancel this screen's queued and running jobs.
    public func stop(jobs: JobsStore) {
        for id in submittedJobIDs where !(jobs.job(id)?.state.isTerminal ?? true) {
            jobs.cancel(id)
        }
    }

    public func latestJob(in jobs: JobsStore) -> JobSnapshot? {
        submittedJobIDs.reversed().lazy.compactMap { jobs.job($0) }.first
    }

    public func hasActiveJobs(in jobs: JobsStore) -> Bool {
        submittedJobIDs.contains { !(jobs.job($0)?.state.isTerminal ?? true) }
    }
}
