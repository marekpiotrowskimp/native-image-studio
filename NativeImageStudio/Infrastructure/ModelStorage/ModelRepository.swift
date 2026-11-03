import Domain
import Foundation

public enum ModelStorageError: Error, Sendable, Equatable, LocalizedError {
    case unknownModel(String)
    case invalidManifest(String, String)

    public var errorDescription: String? {
        switch self {
        case .unknownModel(let id): "Nieznany model: \(id)."
        case .invalidManifest(let file, let reason): "Niepoprawny manifest \(file): \(reason)"
        }
    }
}

/// Model Registry: built-in manifests (bundled JSON) + user manifests from
/// `~/Library/Application Support/NativeImageStudio/Models/*.json`.
public actor ModelRepository {
    private var descriptors: [String: ModelDescriptor] = [:]
    public nonisolated let userManifestDirectory: URL?

    public init(builtIn: [ModelDescriptor] = ModelRepository.bundledManifests(), userManifestDirectory: URL? = nil) {
        self.userManifestDirectory = userManifestDirectory
        for d in builtIn { descriptors[d.id] = d }
        if let dir = userManifestDirectory {
            for d in (try? Self.loadManifests(in: dir)) ?? [] { descriptors[d.id] = d }
        }
    }

    public static var defaultUserManifestDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NativeImageStudio/Models", isDirectory: true)
    }

    public func all() -> [ModelDescriptor] {
        descriptors.values.sorted { $0.name < $1.name }
    }

    public func descriptor(id: String) throws -> ModelDescriptor {
        guard let d = descriptors[id] else { throw ModelStorageError.unknownModel(id) }
        return d
    }

    public func register(_ descriptor: ModelDescriptor) {
        descriptors[descriptor.id] = descriptor
    }

    // MARK: Manifests

    public static func decodeManifest(_ data: Data, name: String = "manifest") throws -> ModelDescriptor {
        do {
            let d = try JSONDecoder().decode(ModelDescriptor.self, from: data)
            guard !d.id.isEmpty else { throw ModelStorageError.invalidManifest(name, "puste id") }
            guard !d.capabilities.isEmpty else { throw ModelStorageError.invalidManifest(name, "brak capabilities") }
            guard d.maxReferenceImages >= 0 else { throw ModelStorageError.invalidManifest(name, "maxReferenceImages < 0") }
            return d
        } catch let error as ModelStorageError {
            throw error
        } catch {
            throw ModelStorageError.invalidManifest(name, String(describing: error))
        }
    }

    public static func loadManifests(in directory: URL) throws -> [ModelDescriptor] {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return try files.map { try decodeManifest(Data(contentsOf: $0), name: $0.lastPathComponent) }
    }

    public static func bundledManifests() -> [ModelDescriptor] {
        guard let dir = Bundle.module.url(forResource: "Manifests", withExtension: nil) else { return [] }
        return (try? loadManifests(in: dir)) ?? []
    }
}
