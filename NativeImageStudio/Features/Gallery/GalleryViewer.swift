import SwiftUI

/// Full-size viewer over the gallery: zoom (pinch, ⌘-scroll, ⌘+ / ⌘−, double-click),
/// ← / → between the filtered images, ⌫ deletes (after confirmation), Esc closes.
struct GalleryViewer<MoveMenu: View>: View {
    let items: [GalleryItem]
    let store: GalleryStore
    let onDelete: (GalleryItem) -> Void
    @ViewBuilder let moveMenu: (GalleryItem) -> MoveMenu

    var body: some View {
        if let id = store.viewerItemID, let index = items.firstIndex(where: { $0.id == id }) {
            let item = items[index]
            let zoom = store.viewerZoom
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Button { show(-1, from: item) } label: { Image(systemName: "chevron.left") }
                        .keyboardShortcut(.leftArrow, modifiers: [])
                        .disabled(index == 0)
                        .help("Poprzedni (←)")
                    Button { show(1, from: item) } label: { Image(systemName: "chevron.right") }
                        .keyboardShortcut(.rightArrow, modifiers: [])
                        .disabled(index == items.count - 1)
                        .help("Następny (→)")
                    Text("\(index + 1) / \(items.count)").monospacedDigit()
                    Text("\(item.width) × \(item.height)").foregroundStyle(.secondary)
                    if let folder = store.folder(of: item) {
                        Label(folder, systemImage: "folder").foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button { zoom.zoomOut() } label: { Image(systemName: "minus.magnifyingglass") }
                        .keyboardShortcut("-", modifiers: .command)
                        .help("Pomniejsz (⌘−)")
                    Text("\(Int((zoom.magnification * 100).rounded())) %")
                        .monospacedDigit().frame(width: 52)
                    Button { zoom.zoomIn() } label: { Image(systemName: "plus.magnifyingglass") }
                        .keyboardShortcut("=", modifiers: .command)
                        .help("Powiększ (⌘+)")
                    Button("Dopasuj") { zoom.fit() }
                        .keyboardShortcut("0", modifiers: .command)
                        .help("Cały obraz w oknie (⌘0)")
                    Button("100 %") { zoom.actualSize() }
                        .keyboardShortcut("1", modifiers: .command)
                        .help("Rzeczywisty rozmiar (⌘1)")
                    Menu { moveMenu(item) } label: { Image(systemName: "folder") }
                        .fixedSize()
                        .help("Przenieś do folderu")
                    Button(role: .destructive) { onDelete(item) } label: { Image(systemName: "trash") }
                        .keyboardShortcut(.delete, modifiers: [])
                        .help("Przenieś do Kosza (⌫)")
                    Button { store.viewerItemID = nil } label: { Image(systemName: "xmark") }
                        .keyboardShortcut(.cancelAction)
                        .help("Zamknij (Esc)")
                }
                .padding(8)
                .background(.bar)
                ZoomableImageView(url: item.fileURL, controller: zoom)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
                    .accessibilityLabel(item.prompt)
                Text(item.prompt)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.bar)
            }
        }
    }

    private func show(_ offset: Int, from item: GalleryItem) {
        if let next = GalleryStore.neighbor(of: item.id, offset: offset, in: items.map(\.id)) {
            store.viewerItemID = next
        }
    }
}
