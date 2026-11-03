import Application
import Domain
import Foundation
import Infrastructure

/// Everything the UI layer needs, with no reference to a concrete engine.
public struct AppServices: Sendable {
    public let coordinator: GenerationCoordinator
    public let batches: BatchCoordinator
    public let registry: EngineRegistry
    public let models: ModelRepository
    public let images: ImageRepository
    public let memory: MemoryBudgetManager

    public init(
        coordinator: GenerationCoordinator,
        batches: BatchCoordinator,
        registry: EngineRegistry,
        models: ModelRepository,
        images: ImageRepository,
        memory: MemoryBudgetManager
    ) {
        self.coordinator = coordinator
        self.batches = batches
        self.registry = registry
        self.models = models
        self.images = images
        self.memory = memory
    }

    /// Installer for a model's backend, if that engine manages weights.
    public func installer(for model: ModelDescriptor) -> (any ModelWeightsProvider)? {
        (try? registry.engine(for: model)) as? any ModelWeightsProvider
    }
}

/// Error text for the UI.
public func userMessage(_ error: any Error) -> String {
    (error as? any LocalizedError)?.errorDescription ?? String(describing: error)
}
