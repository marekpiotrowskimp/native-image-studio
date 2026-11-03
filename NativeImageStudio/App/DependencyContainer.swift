import Application
import CoreMLEngine
import Domain
import Features
import Foundation
import Infrastructure
import MLXEngine
import PromptAssistant
import SwiftData

/// Composition root: the only place that knows which engines exist.
@MainActor
final class DependencyContainer {
    let settings: AppSettings
    let services: AppServices
    let probe: any SystemMemoryProbe
    let jobs: JobsStore
    let catalog: ModelCatalogStore
    let gallery: GalleryStore
    let generation: GenerationViewModel
    let editing: ImageEditingViewModel
    let navigation = AppNavigation()
    let profiles: ProfilesStore
    let benchmarkLog: BenchmarkLog
    let assistant: PromptAssistantStore

    init() {
        settings = AppSettings.load()
        let models = ModelRepository(userManifestDirectory: ModelRepository.defaultUserManifestDirectory)
        // Self-check sandbox: a separate output directory and an in-memory gallery index, so the
        // folder scenario never moves the user's own images.
        let sandbox = ProcessInfo.processInfo.environment["NIS_SELFCHECK_GALLERY"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        let images = ImageRepository(outputDirectory: sandbox ?? settings.outputDirectory)
        let mlx = MLXGenerationEngine(models: models, images: images)
        let coreML = CoreMLGenerationEngine(models: models, images: images)
        let registry = EngineRegistry([mlx, coreML])
        let applyPreview = { @Sendable (mode: LivePreviewMode) -> Void in
            Task { for engine in registry.all { await engine.setLivePreview(mode) } }
        }
        applyPreview(settings.livePreview)
        NotificationCenter.default.addObserver(forName: AppSettings.didChange, object: nil, queue: .main) { _ in
            applyPreview(AppSettings.load().livePreview)
        }
        probe = DarwinMemoryProbe(gpu: MLXGPUMemory())
        let memory = MemoryBudgetManager(probe: probe, config: settings.memory)
        let coordinator = GenerationCoordinator(
            registry: registry, models: models, memory: memory,
            maxUpdatesPerSecond: settings.progressUpdatesPerSecond)
        services = AppServices(
            coordinator: coordinator, batches: BatchCoordinator(coordinator: coordinator),
            registry: registry, models: models, images: images, memory: memory)

        let writer = MLXPromptAssistant(coordinator: coordinator)
        assistant = PromptAssistantStore(writer: writer)
        Task { await coordinator.register(resident: writer) }

        jobs = JobsStore(services: services)
        catalog = ModelCatalogStore(services: services)
        let container: ModelContainer
        do {
            container = try GalleryStore.makeContainer(inMemory: sandbox != nil)
        } catch {
            // A broken index must not block the app; files on disk remain the source of truth.
            container = try! GalleryStore.makeContainer(inMemory: true)
        }
        gallery = sandbox == nil
            ? GalleryStore(container: container, images: images)
            : GalleryStore(container: container, images: images, trash: { try FileManager.default.removeItem(at: $0) })
        generation = GenerationViewModel(services: services, catalog: catalog)
        editing = ImageEditingViewModel(services: services, catalog: catalog)

        profiles = ProfilesStore(store: ProfileStore(fileURL: ProfileStore.defaultFileURL))
        benchmarkLog = BenchmarkLog(fileURL: BenchmarkRecorder.defaultLogURL)
        let recorder = BenchmarkRecorder(log: benchmarkLog)
        let gallery = self.gallery
        let catalog = self.catalog
        jobs.onCompleted = { image in
            gallery.add(image)
            recorder.append(image, model: catalog.entries.first { $0.id == image.metadata.modelID }?.descriptor)
        }
    }
}
