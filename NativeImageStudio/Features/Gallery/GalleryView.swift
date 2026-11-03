import AppKit
import Domain
import SwiftData
import SwiftUI

public struct GalleryView: View {
    let store: GalleryStore
    @Query(filter: #Predicate<GalleryItem> { !$0.isHidden }, sort: \GalleryItem.createdAt, order: .reverse)
    private var items: [GalleryItem]
    @State private var selection: Set<GalleryItem.ID> = []
    @State private var anchor: GalleryItem.ID?
    @State private var search = ""
    @State private var modeFilter: String = "all"
    @State private var confirmingRemoval = false
    @State private var removalMessage: String?
    @State private var folderPrompt: FolderPrompt?
    @State private var folderName = ""

    public init(store: GalleryStore) {
        self.store = store
    }

    /// Mode and search filters (the folder bar counts over these).
    private var searched: [GalleryItem] {
        items.filter { item in
            (modeFilter == "all" || item.modeKind == modeFilter)
                && (search.isEmpty || item.prompt.localizedCaseInsensitiveContains(search))
        }
    }

    private var filtered: [GalleryItem] {
        searched.filter { store.matches($0, store.folderFilter) }
    }

    private var selectedItems: [GalleryItem] {
        items.filter { selection.contains($0.id) }
    }

    public var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack {
                    Picker("Tryb", selection: $modeFilter) {
                        Text("Wszystkie").tag("all")
                        ForEach(ModeKind.allCases, id: \.rawValue) { Text($0.polishName).tag($0.rawValue) }
                    }
                    .frame(maxWidth: 220)
                    Spacer()
                    if selection.isEmpty {
                        Text("\(filtered.count) obrazów").foregroundStyle(.secondary)
                    } else {
                        Text("Zaznaczono \(selection.count)").foregroundStyle(.secondary)
                        Button("Odznacz") { selection.removeAll() }
                        Menu {
                            moveMenu(for: selectedItems)
                        } label: {
                            Label("Przenieś do", systemImage: "folder")
                        }
                        .fixedSize()
                        Button(role: .destructive) { confirmingRemoval = true } label: {
                            Label("Usuń (\(selection.count))", systemImage: "trash")
                        }
                        // The viewer has its own ⌫ while open.
                        .keyboardShortcut(store.viewerItemID == nil ? KeyboardShortcut(.delete, modifiers: []) : nil)
                    }
                    Button("Zaznacz wszystko") { selection = Set(filtered.map(\.id)) }
                        .keyboardShortcut("a", modifiers: .command)
                        .disabled(filtered.isEmpty)
                }
                .padding(8)
                GalleryFolderBar(store: store, counts: store.counts(in: searched), total: searched.count) { prompt($0) }
                    .padding(.bottom, 4)
                if let message = removalMessage ?? store.folderError {
                    Text(message).font(.caption).foregroundStyle(.orange).padding(.horizontal, 8)
                }
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 8)], spacing: 8) {
                        ForEach(filtered) { item in
                            GalleryCell(item: item, selected: selection.contains(item.id), showsCheckmark: selection.count > 1)
                                .gesture(TapGesture(count: 2).onEnded { open(item.id) })
                                .simultaneousGesture(TapGesture().onEnded { select(item.id) })
                                .contextMenu {
                                    Button("Powiększ") { open(item.id) }
                                    Menu("Przenieś do") {
                                        moveMenu(for: selection.contains(item.id) ? selectedItems : [item])
                                    }
                                    Button("Przenieś do Kosza") {
                                        if !selection.contains(item.id) { selection = [item.id] }
                                        confirmingRemoval = true
                                    }
                                }
                                .accessibilityLabel(item.prompt)
                                .accessibilityAddTraits(selection.contains(item.id) ? .isSelected : [])
                        }
                    }
                    .padding(8)
                }
            }
            .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
            .searchable(text: $search, prompt: "Szukaj w promptach")

            Divider()

            Group {
                if selection.count == 1, let item = items.first(where: { selection.contains($0.id) }) {
                    GalleryDetailView(item: item, store: store) { open(item.id) }
                } else if selection.count > 1 {
                    ContentUnavailableView("Zaznaczono \(selection.count) obrazów", systemImage: "square.stack",
                                           description: Text("⌘-klik dodaje/odejmuje, ⇧-klik zaznacza zakres. Usuń: przycisk u góry lub klawisz ⌫."))
                } else {
                    ContentUnavailableView("Wybierz obraz", systemImage: "photo.on.rectangle.angled",
                                           description: Text("Dwuklik powiększa obraz. ⌘-klik lub ⇧-klik zaznacza wiele obrazów."))
                }
            }
            .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay {
            if store.viewerItemID != nil {
                GalleryViewer(items: filtered, store: store,
                              onDelete: { item in
                                  selection = [item.id]
                                  confirmingRemoval = true
                              },
                              moveMenu: { item in moveMenu(for: [item]) })
            }
        }
        .onChange(of: store.viewerItemID) { _, id in
            // The detail pane follows the viewer, so closing it leaves the last image selected.
            if let id { selection = [id]; anchor = id }
        }
        .task { _ = await store.importFromDisk() }
        .alert(folderPrompt?.title ?? "", isPresented: Binding(
            get: { folderPrompt != nil }, set: { if !$0 { folderPrompt = nil } })) {
            TextField("Nazwa folderu", text: $folderName)
            Button(folderPrompt?.id == "create" ? "Utwórz" : "Zmień nazwę") { commitFolderPrompt() }
                .disabled(folderName.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Anuluj", role: .cancel) {}
        }
        .confirmationDialog("Usunąć \(selection.count) \(selection.count == 1 ? "obraz" : "obrazy/obrazów")?",
                            isPresented: $confirmingRemoval) {
            Button("Przenieś do Kosza", role: .destructive) { remove(.moveFilesToTrash) }
            Button("Tylko ukryj w galerii (pliki zostają)") { remove(.hideOnly) }
            Button("Anuluj", role: .cancel) {}
        } message: {
            Text("Usuwane są tylko wygenerowane wyniki i ich metadane. Zdjęcia wejściowe pozostają nietknięte. Pliki z Kosza można przywrócić.")
        }
    }

    /// Click: single; ⌘-click: toggle; ⇧-click: range from the last anchor.
    private func select(_ id: GalleryItem.ID) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.shift), let anchor {
            selection.formUnion(GalleryStore.range(from: anchor, to: id, in: filtered.map(\.id)))
        } else if flags.contains(.command) {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            anchor = id
        } else {
            selection = [id]
            anchor = id
        }
    }

    @ViewBuilder
    private func moveMenu(for chosen: [GalleryItem]) -> some View {
        let folders = Set(chosen.map { store.folder(of: $0) })
        FolderMoveMenuItems(folders: store.folders, current: folders.count == 1 ? folders.first ?? nil : nil,
                            onMove: { store.move(chosen, to: $0) },
                            onNewFolder: { prompt(.create(moving: Set(chosen.map(\.id)))) })
    }

    private func prompt(_ prompt: FolderPrompt) {
        if case .rename(let name) = prompt { folderName = name } else { folderName = "" }
        folderPrompt = prompt
    }

    private func commitFolderPrompt() {
        guard let folderPrompt else { return }
        switch folderPrompt {
        case .create(let moving):
            if let name = store.createFolder(folderName), !moving.isEmpty {
                store.move(items.filter { moving.contains($0.id) }, to: name)
            }
        case .rename(let old):
            store.renameFolder(old, to: folderName)
        }
        self.folderPrompt = nil
    }

    private func open(_ id: GalleryItem.ID) {
        store.viewerItemID = id
    }

    private func remove(_ mode: GalleryStore.RemovalMode) {
        let failures = store.remove(selectedItems, mode: mode, visibleOrder: filtered.map(\.id))
        removalMessage = failures > 0 ? "Nie udało się przenieść \(failures) plików do Kosza." : nil
        selection.removeAll()
    }
}

/// Square grid cell showing the whole image at its own aspect ratio (letterboxed), so wide or
/// tall results never spill into neighbouring cells or their click areas.
struct GalleryCell: View {
    let item: GalleryItem
    let selected: Bool
    let showsCheckmark: Bool

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                ThumbnailView(url: item.fileURL, maxPixel: 320, contentMode: .fit)
                    .clipShape(.rect(cornerRadius: 3))
                    .padding(4)
            }
            .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.accentColor, lineWidth: selected ? 3 : 0)
            }
            .overlay(alignment: .topTrailing) {
                if selected && showsCheckmark {
                    Image(systemName: "checkmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.accentColor)
                        .font(.title3).padding(6)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if !item.inputPaths.isEmpty {
                    Image(systemName: "photo.on.rectangle").padding(4)
                        .background(.thinMaterial, in: .rect(cornerRadius: 4)).padding(4)
                }
            }
            .contentShape(.rect(cornerRadius: 6))
            .help("\(item.width) × \(item.height)")
    }
}

struct GalleryDetailView: View {
    let item: GalleryItem
    let store: GalleryStore
    let openViewer: () -> Void
    @State private var compare = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if compare, let before = item.inputURLs.first {
                    BeforeAfterView(before: before, after: item.fileURL).frame(minHeight: 360)
                } else {
                    ThumbnailView(url: item.fileURL, maxPixel: 1600, contentMode: .fit)
                        .frame(maxWidth: .infinity, minHeight: 300)
                        .onTapGesture(count: 2, perform: openViewer)
                        .help("Dwuklik: powiększ")
                }
                HStack {
                    if !item.inputPaths.isEmpty {
                        Toggle("Przed/po", isOn: $compare).toggleStyle(.button)
                    }
                    Button("Powiększ", systemImage: "arrow.up.left.and.arrow.down.right", action: openViewer)
                    Button("Pokaż w Finderze") { NSWorkspace.shared.activateFileViewerSelecting([item.fileURL]) }
                    Button("Kopiuj prompt") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(item.prompt, forType: .string)
                    }
                    Spacer()
                    Button(role: .destructive) { store.delete(item, moveFileToTrash: true) } label: { Text("Przenieś do Kosza") }
                }
                Text(item.prompt).textSelection(.enabled)
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    row("Folder", store.folder(of: item) ?? "—")
                    row("Tryb", item.mode?.polishName ?? item.modeKind)
                    if let s = item.strength { row("Siła", String(format: "%.2f", s)) }
                    row("Model", "\(item.modelID) (\(item.backend))")
                    row("Rozmiar", "\(item.width) × \(item.height)")
                    row("Kroki / guidance", "\(item.steps) / \(String(format: "%.1f", item.guidance))")
                    row("Seed", item.seedText)
                    if item.elapsedSeconds > 0 { row("Czas", String(format: "%.1f s", item.elapsedSeconds)) }
                    if let b = item.batchID { row("Partia", b.uuidString.prefix(8).description) }
                    row("Utworzono", item.createdAt.formatted(date: .abbreviated, time: .standard))
                }
                .font(.callout)
                if !item.inputPaths.isEmpty {
                    Text("Obrazy wejściowe").font(.headline)
                    ScrollView(.horizontal) {
                        HStack {
                            ForEach(Array(item.inputURLs.enumerated()), id: \.offset) { i, url in
                                VStack {
                                    ThumbnailView(url: url, maxPixel: 200).frame(width: 90, height: 90).clipShape(.rect(cornerRadius: 6))
                                    Text("obraz \(i + 1)").font(.caption2)
                                    Text(item.inputHashes.indices.contains(i) ? String(item.inputHashes[i].prefix(10)) : "")
                                        .font(.caption2.monospaced()).foregroundStyle(.secondary)
                                }
                                .help(url.path)
                            }
                        }
                    }
                }
            }
            .padding()
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }
}
