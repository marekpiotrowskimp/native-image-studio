import Domain
import Foundation

public enum EngineRegistryError: Error, Sendable, Equatable, LocalizedError {
    case noEngine(BackendKind)

    public var errorDescription: String? {
        switch self {
        case .noEngine(let b): "Brak silnika dla backendu \(b.rawValue)."
        }
    }
}

/// Maps a model's backend to the engine instance that serves it.
public struct EngineRegistry: Sendable {
    private let engines: [BackendKind: any ImageGenerationEngine]

    public init(_ engines: [any ImageGenerationEngine]) {
        var map: [BackendKind: any ImageGenerationEngine] = [:]
        for e in engines { map[e.backend] = e }
        self.engines = map
    }

    public var all: [any ImageGenerationEngine] {
        BackendKind.allCases.compactMap { engines[$0] }
    }

    public func engine(for backend: BackendKind) throws -> any ImageGenerationEngine {
        guard let e = engines[backend] else { throw EngineRegistryError.noEngine(backend) }
        return e
    }

    public func engine(for model: ModelDescriptor) throws -> any ImageGenerationEngine {
        try engine(for: model.backend)
    }

    /// What the UI may offer for a model: manifest capabilities intersected with the engine's.
    public func capabilities(for model: ModelDescriptor) async throws -> EngineCapabilities {
        let engine = try engine(for: model)
        if let caps = await engine.capabilities(forModel: model.id) { return caps }
        var caps = model.engineCapabilities(cancellation: engine.capabilities.cancellation)
        caps.supportedModes.formIntersection(engine.capabilities.supportedModes)
        return caps
    }
}
