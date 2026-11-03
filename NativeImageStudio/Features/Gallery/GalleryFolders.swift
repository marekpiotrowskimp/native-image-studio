import AppKit
import SwiftData
import SwiftUI

/// Name prompt for creating or renaming a folder.
enum FolderPrompt: Identifiable, Equatable {
    /// New folder; `moving` images go into it once created.
    case create(moving: Set<PersistentIdentifier>)
    case rename(String)

    var id: String {
        switch self {
        case .create: "create"
        case .rename(let name): "rename-\(name)"
        }
    }

    var title: String {
        switch self {
        case .create(let moving): moving.isEmpty ? "Nowy folder" : "Nowy folder dla \(moving.count) obrazów"
        case .rename(let name): "Zmień nazwę folderu „\(name)”"
        }
    }
}

/// Folder chips above the grid: filter, create, rename, delete.
struct GalleryFolderBar: View {
    let store: GalleryStore
    /// Counts over the images visible with the other filters (nil key: outside folders).
    let counts: [String?: Int]
    let total: Int
    let onPrompt: (FolderPrompt) -> Void
    @State private var deleting: String?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip("Wszystkie", systemImage: "photo.on.rectangle.angled", count: total, filter: .all)
                chip("Bez folderu", systemImage: "tray", count: counts[nil] ?? 0, filter: .unfiled)
                ForEach(store.folders, id: \.self) { name in
                    chip(name, systemImage: "folder", count: counts[name] ?? 0, filter: .folder(name))
                        .contextMenu {
                            Button("Zmień nazwę…") { onPrompt(.rename(name)) }
                            Button("Usuń folder…", role: .destructive) { deleting = name }
                            Button("Pokaż w Finderze") {
                                NSWorkspace.shared.activateFileViewerSelecting(
                                    [store.foldersRoot.appendingPathComponent(name, isDirectory: true)])
                            }
                        }
                }
                Button { onPrompt(.create(moving: [])) } label: { Label("Nowy folder", systemImage: "folder.badge.plus") }
                    .buttonStyle(.borderless)
                    .padding(.horizontal, 6)
            }
            .padding(.horizontal, 8)
        }
        .confirmationDialog("Usunąć folder „\(deleting ?? "")”?", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Usuń folder", role: .destructive) {
                if let deleting { store.deleteFolder(deleting) }
            }
            Button("Anuluj", role: .cancel) {}
        } message: {
            Text("Obrazy z folderu wrócą do galerii głównej — żaden obraz nie zostanie usunięty.")
        }
    }

    private func chip(_ title: String, systemImage: String, count: Int, filter: GalleryFolderFilter) -> some View {
        let selected = store.folderFilter == filter
        return Button { store.folderFilter = filter } label: {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                Text(title).lineLimit(1)
                Text("\(count)").monospacedDigit().foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(selected ? Color.accentColor : Color.secondary.opacity(0.15), in: .capsule)
            .foregroundStyle(selected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// "Przenieś do" menu items: every folder, a new one, or out of folders.
struct FolderMoveMenuItems: View {
    let folders: [String]
    /// Folder shared by all chosen images (its entry is disabled).
    let current: String?
    let onMove: (String?) -> Void
    let onNewFolder: () -> Void

    var body: some View {
        ForEach(folders, id: \.self) { name in
            Button(name, systemImage: "folder") { onMove(name) }
                .disabled(name == current)
        }
        if !folders.isEmpty { Divider() }
        Button("Nowy folder…", systemImage: "folder.badge.plus", action: onNewFolder)
        Button("Usuń z folderu", systemImage: "tray") { onMove(nil) }
    }
}
