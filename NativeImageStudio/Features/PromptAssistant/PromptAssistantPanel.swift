import Domain
import SwiftUI

/// "Asystent promptu" section of the generation form.
struct PromptAssistantPanel: View {
    @Bindable var assistant: PromptAssistantStore
    @Binding var prompt: String
    let style: PromptStyle?

    var body: some View {
        if !assistant.installed {
            VStack(alignment: .leading, spacing: 6) {
                Text("Lokalny model językowy pisze realistyczne opisy scen w formacie wybranego modelu obrazów.")
                    .font(.caption).foregroundStyle(.secondary)
                if let progress = assistant.installProgress {
                    ProgressView(value: progress) { Text(assistant.installMessage ?? "Pobieranie…").font(.caption) }
                } else {
                    Button("Pobierz \(assistant.modelName) (\(assistant.downloadSize))") { assistant.install() }
                    if let message = assistant.installMessage {
                        Text(message).font(.caption).foregroundStyle(.red)
                    }
                }
            }
        } else {
            TextField("Pomysł na scenę", text: $assistant.idea,
                      prompt: Text("Opisz scenę, np. „starszy rybak na molo o świcie, mgła”"), axis: .vertical)
                .labelsHidden()
                .lineLimit(2...5)
                .accessibilityLabel("Pomysł na scenę")
            let can = assistant.canWrite(currentPrompt: prompt)
            HStack {
                Button("Napisz prompt") { write(refining: nil) }
                    .disabled(!can.new || assistant.status.isWorking || style == nil)
                Button("Popraw obecny") { write(refining: prompt) }
                    .disabled(!can.refine || assistant.status.isWorking || style == nil)
                    .help("Przepisuje prompt z edytora; tekst powyżej (jeśli jest) to zmiana do wprowadzenia.")
                if assistant.status.isWorking {
                    Button("Stop", role: .cancel) { assistant.stop() }
                }
            }
            if let style {
                Text("Format: \(style.polishLabel)").font(.caption2).foregroundStyle(.secondary)
            }
            if let label = assistant.status.label {
                HStack(spacing: 6) {
                    if assistant.status.isWorking { ProgressView().controlSize(.small) }
                    Text(label).font(.caption)
                        .foregroundStyle(assistant.status == .idle || assistant.status.isWorking ? Color.secondary : Color.red)
                }
            }
            if !assistant.draft.isEmpty {
                Text(assistant.draft)
                    .font(.callout).textSelection(.enabled)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 6))
                    .accessibilityLabel("Propozycja promptu")
                if !assistant.status.isWorking {
                    HStack {
                        Button("Użyj") {
                            prompt = assistant.draft
                            assistant.discardDraft()
                        }
                        .keyboardShortcut(.return, modifiers: [.command, .shift])
                        Button("Odrzuć") { assistant.discardDraft() }
                    }
                }
            }
        }
    }

    private func write(refining current: String?) {
        guard let style else { return }
        assistant.write(refining: current, style: style)
    }
}

extension PromptStyle {
    var polishLabel: String {
        switch self {
        case .naturalLanguage: "pełne zdania (FLUX, Z-Image)"
        case .sdxlPhrases: "frazy po przecinku, do ~55 słów (SDXL)"
        case .ponyTags: "tagi Pony ze score_9…"
        case .booruTags: "tagi Danbooru (Illustrious)"
        }
    }
}

/// Model library row for the assistant's language model.
struct PromptAssistantModelRow: View {
    @Bindable var assistant: PromptAssistantStore
    @State private var confirmRemoval = false

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(assistant.modelName).font(.headline)
                Text("Asystent promptów · MLX · tekst · Apache-2.0 (huihui-ai/Huihui-Qwen3-8B-abliterated-v2)")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Wersja „abliterated”: bez wbudowanych odmów. Ładowany przy pierwszym użyciu (~4,3 GB pamięci); zwalniany przed generowaniem obrazu.")
                    .font(.caption2).foregroundStyle(.secondary)
                if let progress = assistant.installProgress {
                    ProgressView(value: progress) { Text(assistant.installMessage ?? "").font(.caption2) }
                } else if let message = assistant.installMessage {
                    Text(message).font(.caption2).foregroundStyle(.red)
                }
            }
            Spacer()
            if assistant.installed {
                Label("Zainstalowany", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
                Button(role: .destructive) { confirmRemoval = true } label: { Image(systemName: "trash") }
                    .help("Usuń model asystenta z dysku")
            } else if assistant.installProgress == nil {
                Button("Pobierz (\(assistant.downloadSize))") { assistant.install() }
            }
        }
        .padding(.vertical, 4)
        .confirmationDialog("Usunąć model asystenta promptów?", isPresented: $confirmRemoval) {
            Button("Usuń", role: .destructive) { assistant.remove() }
        }
    }
}
