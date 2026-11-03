import Application
import Domain
import Foundation
import Observation

/// Models, their effective capabilities and install state; also the current selection.
@MainActor
@Observable
public final class ModelCatalogStore {
    public struct Entry: Identifiable, Equatable {
        public let descriptor: ModelDescriptor
        public var capabilities: EngineCapabilities?
        public var installed: Bool
        public var installProgress: Double?
        public var installMessage: String?
        public var error: String?
        public var sizeBytes: Int64 = 0
        public var keptShared: [String] = []
        public var id: String { descriptor.id }
    }

    public private(set) var entries: [Entry] = []
    public var selectedModelID: String?

    private let services: AppServices

    public init(services: AppServices) {
        self.services = services
    }

    public var selected: Entry? {
        entries.first { $0.id == selectedModelID } ?? entries.first
    }

    public var selectedCapabilities: EngineCapabilities? { selected?.capabilities }

    public func reload() async {
        let descriptors = await services.models.all()
        var result: [Entry] = []
        for d in descriptors {
            let caps = try? await services.registry.capabilities(for: d)
            let installer = services.installer(for: d)
            let installed = await installer?.isInstalled(modelID: d.id) ?? true
            var entry = Entry(descriptor: d, capabilities: caps, installed: installed)
            entry.sizeBytes = await installer?.installedSizeBytes(modelID: d.id) ?? 0
            result.append(entry)
        }
        entries = result
        if selectedModelID == nil || !entries.contains(where: { $0.id == selectedModelID }) {
            selectedModelID = entries.first(where: \.installed)?.id ?? entries.first?.id
        }
    }

    public func install(_ modelID: String) {
        guard let i = entries.firstIndex(where: { $0.id == modelID }),
              let installer = services.installer(for: entries[i].descriptor) else { return }
        entries[i].installProgress = 0
        entries[i].error = nil
        Task {
            do {
                try await installer.install(modelID: modelID) { fraction, message in
                    Task { @MainActor in self.updateProgress(modelID, fraction, message) }
                }
                await reload()
            } catch {
                setError(modelID, userMessage(error))
            }
        }
    }

    /// Deletes the model's weights. Shared components that were kept are reported.
    public func remove(_ modelID: String) {
        guard let entry = entries.first(where: { $0.id == modelID }),
              let installer = services.installer(for: entry.descriptor) else { return }
        Task {
            do {
                let kept = try await installer.remove(modelID: modelID)
                await reload()
                if let i = entries.firstIndex(where: { $0.id == modelID }) { entries[i].keptShared = kept }
            } catch {
                setError(modelID, userMessage(error))
            }
        }
    }

    private func updateProgress(_ id: String, _ fraction: Double, _ message: String) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].installProgress = fraction
        entries[i].installMessage = message
    }

    private func setError(_ id: String, _ message: String) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].installProgress = nil
        entries[i].error = message
    }
}
