import Domain
import Foundation
import Infrastructure
import Observation
import SwiftData

/// Which images the grid shows.
public enum GalleryFolderFilter: Hashable, Sendable {
    case all
    /// Images outside any folder.
    case unfiled
    case folder(String)
}

@MainActor
@Observable
public final class GalleryStore {
    public let container: ModelContainer
    private let images: ImageRepository

    /// Moves a file to the Trash (injectable so tests do not fill the user's Trash).
    private let trash: (URL) throws -> Void

    /// Item open in the full-size viewer (nil: viewer closed) and its zoom.
    public var viewerItemID: PersistentIdentifier?
    public let viewerZoom = ZoomController()

    /// Subfolders of `<output>/Foldery/`, sorted by name.
    public private(set) var folders: [String] = []
    public var folderFilter: GalleryFolderFilter = .all
    /// Last failed folder operation, shown above the grid.
    public var folderError: String?

    public init(container: ModelContainer, images: ImageRepository,
                trash: @escaping (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) {
        self.container = container
        self.images = images
        self.trash = trash
    }

    public static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        let config = ModelConfiguration("Gallery", isStoredInMemoryOnly: inMemory)
        return try ModelContainer(for: GalleryItem.self, configurations: config)
    }

    var context: ModelContext { container.mainContext }

    public func add(_ image: GeneratedImage) {
        let id = image.metadata.requestID
        let existing = try? context.fetch(FetchDescriptor<GalleryItem>(predicate: #Predicate { $0.requestID == id }))
        guard existing?.isEmpty ?? true else { return }
        context.insert(GalleryItem(metadata: image.metadata, fileURL: image.fileURL, elapsedSeconds: image.elapsedSeconds))
        try? context.save()
    }

    /// Index files written earlier (e.g. by the CLI or before a database reset).
    public func importFromDisk() async -> Int {
        let entries = await images.allEntries()
        let known = Dictionary(((try? context.fetch(FetchDescriptor<GalleryItem>())) ?? []).map { ($0.requestID, $0) },
                               uniquingKeysWith: { a, _ in a })
        var added = 0
        var changed = false
        for (url, meta) in entries {
            if let item = known[meta.requestID] {
                // Moved in Finder (e.g. between folders): follow the file.
                if item.filePath != url.path, !FileManager.default.fileExists(atPath: item.filePath) {
                    item.filePath = url.path
                    changed = true
                }
                continue
            }
            context.insert(GalleryItem(metadata: meta, fileURL: url, elapsedSeconds: 0))
            added += 1
        }
        if added > 0 || changed { try? context.save() }
        refreshFolders()
        return added
    }

    public enum RemovalMode: Sendable {
        /// Move the generated PNG and its JSON sidecar to the Trash (recoverable) and drop the index entry.
        case moveFilesToTrash
        /// Keep files; hide the entry so it does not reappear on the next disk import.
        case hideOnly
    }

    /// Removes generated results. Input photos referenced by the items are never touched.
    /// Returns the number of items whose files could not be moved to the Trash.
    /// When the viewer shows a removed image it moves on to the next one remaining in
    /// `visibleOrder` (the previous one at the end), or closes.
    @discardableResult
    public func remove(_ items: [GalleryItem], mode: RemovalMode, visibleOrder: [PersistentIdentifier] = []) -> Int {
        let removed = Set(items.map(\.id))
        if let open = viewerItemID, removed.contains(open) {
            let remaining = visibleOrder.filter { !removed.contains($0) || $0 == open }
            viewerItemID = Self.neighbor(of: open, offset: 1, in: remaining)
                ?? Self.neighbor(of: open, offset: -1, in: remaining)
        }
        var failures = 0
        for item in items {
            switch mode {
            case .hideOnly:
                item.isHidden = true
            case .moveFilesToTrash:
                do {
                    if FileManager.default.fileExists(atPath: item.fileURL.path) {
                        try trash(item.fileURL)
                    }
                    let sidecar = ImageRepository.sidecarURL(for: item.fileURL)
                    if FileManager.default.fileExists(atPath: sidecar.path) {
                        try trash(sidecar)
                    }
                    context.delete(item)
                } catch {
                    failures += 1
                }
            }
        }
        try? context.save()
        return failures
    }

    public func delete(_ item: GalleryItem, moveFileToTrash: Bool) {
        remove([item], mode: moveFileToTrash ? .moveFilesToTrash : .hideOnly)
    }

    /// Range selection helper: IDs between `anchor` and `target` (inclusive) in `ordered`.
    public static func range<ID: Equatable>(from anchor: ID, to target: ID, in ordered: [ID]) -> [ID] {
        guard let a = ordered.firstIndex(of: anchor), let b = ordered.firstIndex(of: target) else { return [target] }
        return Array(ordered[min(a, b)...max(a, b)])
    }

    // MARK: Folders

    public var foldersRoot: URL { images.foldersRoot }

    public func refreshFolders() {
        folders = images.folders()
        if case .folder(let name) = folderFilter, !folders.contains(name) { folderFilter = .all }
    }

    public func folder(of item: GalleryItem) -> String? {
        images.folderName(of: item.fileURL)
    }

    public func matches(_ item: GalleryItem, _ filter: GalleryFolderFilter) -> Bool {
        switch filter {
        case .all: true
        case .unfiled: folder(of: item) == nil
        case .folder(let name): folder(of: item) == name
        }
    }

    @discardableResult
    public func createFolder(_ name: String) -> String? {
        do {
            let created = try images.createFolder(name)
            folderError = nil
            refreshFolders()
            return created
        } catch {
            folderError = Self.describe(error)
            return nil
        }
    }

    public func renameFolder(_ old: String, to name: String) {
        do {
            let renamed = try images.renameFolder(old, to: name)
            let dir = images.foldersRoot.appendingPathComponent(renamed, isDirectory: true)
            for item in everyItem() where images.folderName(of: item.fileURL) == old {
                item.filePath = dir.appendingPathComponent(item.fileURL.lastPathComponent).path
            }
            try? context.save()
            if folderFilter == .folder(old) { folderFilter = .folder(renamed) }
            folderError = nil
        } catch {
            folderError = Self.describe(error)
        }
        refreshFolders()
    }

    /// Removes the folder; its images go back to the main gallery (nothing is deleted).
    /// Files the gallery does not know about go to the Trash with the directory.
    public func deleteFolder(_ name: String) {
        let contained = everyItem().filter { images.folderName(of: $0.fileURL) == name }
        let failures = move(contained, to: nil)
        guard failures == 0 else { return }
        let dir = images.foldersRoot.appendingPathComponent(name, isDirectory: true)
        let rest = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0 != ".DS_Store" }
        do {
            if rest.isEmpty { try FileManager.default.removeItem(at: dir) } else { try trash(dir) }
            folderError = nil
        } catch {
            folderError = Self.describe(error)
        }
        refreshFolders()
    }

    /// Moves images (PNG + sidecar) into `folder`, or out of any folder when nil.
    /// Returns the number of images that could not be moved.
    @discardableResult
    public func move(_ items: [GalleryItem], to folder: String?) -> Int {
        var failures = 0
        var lastError: (any Error)?
        for item in items {
            do {
                let url = try images.moveImage(at: item.fileURL, toFolder: folder, createdAt: item.createdAt)
                item.filePath = url.path
            } catch {
                failures += 1
                lastError = error
            }
        }
        try? context.save()
        folderError = lastError.map { "Nie udało się przenieść \(failures) obrazów: \(Self.describe($0))" }
        refreshFolders()
        return failures
    }

    /// Image counts per folder (nil key: outside folders), for the folder bar.
    public func counts(in items: [GalleryItem]) -> [String?: Int] {
        var result: [String?: Int] = [:]
        for item in items { result[folder(of: item), default: 0] += 1 }
        return result
    }

    private func everyItem() -> [GalleryItem] {
        (try? context.fetch(FetchDescriptor<GalleryItem>())) ?? []
    }

    private static func describe(_ error: any Error) -> String {
        (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    /// Viewer navigation: the ID `offset` places away from `id` in `ordered`, nil past either end.
    public static func neighbor<ID: Equatable>(of id: ID, offset: Int, in ordered: [ID]) -> ID? {
        guard let i = ordered.firstIndex(of: id), ordered.indices.contains(i + offset) else { return nil }
        return ordered[i + offset]
    }

    public func items(inBatch batchID: UUID) -> [GalleryItem] {
        let descriptor = FetchDescriptor<GalleryItem>(
            predicate: #Predicate { $0.batchID == batchID },
            sortBy: [SortDescriptor(\.createdAt)])
        return (try? context.fetch(descriptor)) ?? []
    }

    public func allItems() -> [GalleryItem] {
        let d = FetchDescriptor<GalleryItem>(predicate: #Predicate { !$0.isHidden },
                                             sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        return (try? context.fetch(d)) ?? []
    }
}
