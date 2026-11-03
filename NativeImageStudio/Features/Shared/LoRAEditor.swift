import AppKit
import Domain
import SwiftUI
import UniformTypeIdentifiers

/// Adds/removes LoRA adapters (.safetensors) with a scale per adapter.
///
/// Uses `NSOpenPanel` directly: a second SwiftUI `.fileImporter` in a hierarchy that
/// already has one (the photo picker on the editing screen) silently never presents.
public struct LoRAEditor: View {
    @Binding var loras: [LoRAReference]

    public init(loras: Binding<[LoRAReference]>) {
        self._loras = loras
    }

    public var body: some View {
        ForEach(Array(loras.enumerated()), id: \.offset) { i, lora in
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(lora.fileURL.deletingPathExtension().lastPathComponent).lineLimit(1)
                    Spacer()
                    Button { loras.remove(at: i) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).help("Usuń adapter")
                }
                HStack {
                    Slider(value: Binding(
                        get: { Double(lora.scale) },
                        set: { loras[i] = LoRAReference(fileURL: lora.fileURL, scale: Float($0), triggerWord: lora.triggerWord) }
                    ), in: 0...2, step: 0.05)
                    Text(String(format: "%.2f", lora.scale)).monospacedDigit().frame(width: 36)
                }
            }
        }
        Button { pick() } label: { Label("Dodaj LoRA…", systemImage: "plus") }
        Text("Plik .safetensors trenowany dla tego modelu. Suwak = siła efektu.")
            .font(.caption2).foregroundStyle(.secondary)
    }

    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NativeImageStudio/LoRA", isDirectory: true)
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.title = "Wybierz adapter LoRA"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if let type = UTType(filenameExtension: "safetensors") { panel.allowedContentTypes = [type] }
        if FileManager.default.fileExists(atPath: Self.defaultDirectory.path) { panel.directoryURL = Self.defaultDirectory }
        guard panel.runModal() == .OK else { return }
        let existing = Set(loras.map(\.fileURL))
        loras += panel.urls.filter { $0.pathExtension.lowercased() == "safetensors" && !existing.contains($0) }
            .map { LoRAReference(fileURL: $0, scale: 1) }
    }
}
