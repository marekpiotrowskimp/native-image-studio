import Domain
import Foundation

/// Persists Model Profiles as one JSON file (`profiles.json`).
public actor ProfileStore {
    public nonisolated let fileURL: URL
    private var profiles: [ModelProfile]

    public init(fileURL: URL) {
        self.fileURL = fileURL
        let decoded = (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode([ModelProfile].self, from: $0) }
        profiles = decoded ?? []
    }

    public static var defaultFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NativeImageStudio/profiles.json")
    }

    public func all() -> [ModelProfile] {
        profiles.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func profiles(forModel modelID: String) -> [ModelProfile] {
        all().filter { $0.modelID == modelID }
    }

    /// Insert or replace (by id).
    public func save(_ profile: ModelProfile) throws {
        if let i = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[i] = profile
        } else {
            profiles.append(profile)
        }
        try persist()
    }

    public func delete(_ id: UUID) throws {
        profiles.removeAll { $0.id == id }
        try persist()
    }

    private func persist() throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(profiles).write(to: fileURL, options: .atomic)
    }
}
