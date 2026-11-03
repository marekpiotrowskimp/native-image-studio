import Domain
import SwiftUI

public struct ModelLibraryView: View {
    @Bindable var catalog: ModelCatalogStore
    let assistant: PromptAssistantStore
    @State private var pendingRemoval: ModelCatalogStore.Entry?

    public init(catalog: ModelCatalogStore, assistant: PromptAssistantStore) {
        self.catalog = catalog
        self.assistant = assistant
    }

    public var body: some View {
        List(selection: $catalog.selectedModelID) {
            Section("Asystent promptów") {
                PromptAssistantModelRow(assistant: assistant)
            }
            Section("Modele obrazów") {
                ForEach(catalog.entries) { entry in
                    ModelRow(entry: entry, install: { catalog.install(entry.id) }, remove: { pendingRemoval = entry })
                        .tag(entry.id)
                }
            }
        }
        .overlay {
            if catalog.entries.isEmpty { ContentUnavailableView("Brak modeli", systemImage: "cube") }
        }
        .confirmationDialog(
            "Usunąć wagi modelu \(pendingRemoval?.descriptor.name ?? "")?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            presenting: pendingRemoval
        ) { entry in
            Button("Usuń (\(ByteCountFormatter.string(fromByteCount: entry.sizeBytes, countStyle: .file)))", role: .destructive) {
                catalog.remove(entry.id)
            }
        } message: { _ in
            Text("Pliki wag zostaną skasowane z dysku. Wygenerowane obrazy pozostaną. Model można pobrać ponownie.")
        }
        .toolbar {
            Button { Task { await catalog.reload(); await assistant.refresh() } } label: { Label("Odśwież", systemImage: "arrow.clockwise") }
        }
    }
}

struct ModelRow: View {
    let entry: ModelCatalogStore.Entry
    let install: () -> Void
    let remove: () -> Void

    var body: some View {
        let d = entry.descriptor
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(d.name).font(.headline)
                Text("\(d.backend.rawValue.uppercased()) · \(d.quantization)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if entry.installed {
                    Label("Pobrany", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
                    if entry.sizeBytes > 0 {
                        Text(ByteCountFormatter.string(fromByteCount: entry.sizeBytes, countStyle: .file))
                            .font(.caption).foregroundStyle(.secondary)
                        Button(role: .destructive, action: remove) { Image(systemName: "trash") }
                            .buttonStyle(.borderless).help("Usuń wagi z dysku")
                    }
                } else if let p = entry.installProgress {
                    ProgressView(value: p).frame(width: 140)
                } else {
                    Button("Pobierz", action: install)
                }
            }
            if let message = entry.installMessage, entry.installProgress != nil {
                Text(message).font(.caption2).foregroundStyle(.secondary)
            }
            if let error = entry.error { Text(error).font(.caption).foregroundStyle(.red) }
            if !entry.keptShared.isEmpty {
                Text("Zachowano współdzielone komponenty: \(entry.keptShared.joined(separator: ", "))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                ForEach(entry.capabilities.map { Array($0.supportedModes).sorted() } ?? [], id: \.self) { mode in
                    Text(mode.polishName).font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.quaternary, in: .capsule)
                }
                if let caps = entry.capabilities, caps.supports(.referenceEdit) {
                    Text("maks. \(caps.maxReferenceImages) ref.").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Text("Licencja: \(d.license)\(d.commercialUse ? "" : " — tylko niekomercyjnie")").font(.caption).foregroundStyle(.secondary)
            Text("Próg pamięci aplikacji: \(Int(d.minimumMemoryGB)) GB"
                 + (d.memory.map { String(format: " · zmierzono: rezydentnie %.1f GB, +%.1f GB/MP", $0.residentGB, $0.activationGBPerMegapixel) } ?? ""))
                .font(.caption).foregroundStyle(.secondary)
            ForEach(d.knownLimitations, id: \.self) { Text("• \($0)").font(.caption2).foregroundStyle(.secondary) }
        }
        .padding(.vertical, 4)
    }
}
