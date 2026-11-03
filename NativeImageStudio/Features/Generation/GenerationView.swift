import Application
import Domain
import SwiftUI

public struct GenerationView: View {
    @Bindable var model: GenerationViewModel
    let jobs: JobsStore
    let catalog: ModelCatalogStore
    let profiles: ProfilesStore
    let assistant: PromptAssistantStore

    public init(model: GenerationViewModel, jobs: JobsStore, catalog: ModelCatalogStore, profiles: ProfilesStore,
                assistant: PromptAssistantStore) {
        self.model = model
        self.assistant = assistant
        self.jobs = jobs
        self.catalog = catalog
        self.profiles = profiles
    }

    public var body: some View {
        HStack(spacing: 0) {
            Form {
                Section("Prompt") {
                    TextEditor(text: $model.prompt)
                        .font(.body)
                        .frame(minHeight: 110)
                        .accessibilityLabel("Prompt")
                    if model.capabilities?.supportsNegativePrompt == true {
                        TextField("Negatywny prompt", text: $model.negativePrompt, axis: .vertical)
                    }
                }
                Section("Asystent promptu") {
                    PromptAssistantPanel(assistant: assistant, prompt: $model.prompt,
                                         style: catalog.selected?.descriptor.effectivePromptStyle)
                }
                Section("Ustawienia") {
                    ModelPicker(catalog: catalog, requiredMode: .textToImage)
                    if model.capabilities.map({ $0.minDimension < $0.maxDimension }) ?? true {
                        Picker("Proporcje", selection: $model.aspect) {
                            ForEach(AspectPreset.textToImageCases) { Text($0.label).tag($0) }
                        }
                    }
                    Picker("Rozdzielczość", selection: $model.resolution) {
                        ForEach(model.capabilities?.supportedResolutions ?? [1024], id: \.self) { Text("\($0) px").tag($0) }
                    }
                    LabeledContent("Wynik", value: "\(model.outputSize.width) × \(model.outputSize.height)")
                    Stepper("Kroki: \(model.steps)", value: $model.steps, in: model.capabilities?.stepRange ?? 1...50)
                    HStack {
                        Text("Guidance")
                        Slider(value: $model.guidance, in: 0...10, step: 0.5)
                        Text(String(format: "%.1f", model.guidance)).monospacedDigit().frame(width: 32)
                    }
                    Toggle("Losowy seed", isOn: $model.randomizeSeed)
                    if !model.randomizeSeed {
                        TextField("Seed", value: $model.seed, format: .number.grouping(.never))
                    }
                    Stepper("Liczba obrazów: \(model.count)", value: $model.count, in: 1...16)
                }
                if model.capabilities?.supportsLoRA == true {
                    Section("Adaptery LoRA") {
                        LoRAEditor(loras: $model.loras)
                        if !model.loras.isEmpty {
                            Text("Zmiana zestawu LoRA przeładowuje model (adaptery są wtapiane w wagi).")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    HStack {
                        Button {
                            Task { await model.generate() }
                        } label: {
                            Label("Generuj", systemImage: "sparkles")
                        }
                        .keyboardShortcut(.return, modifiers: .command)
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canGenerate)

                        Button(role: .cancel) {
                            model.stop(jobs: jobs)
                        } label: {
                            Label("Stop", systemImage: "stop.fill")
                        }
                        .keyboardShortcut(".", modifiers: .command)
                        .disabled(!model.hasActiveJobs(in: jobs))
                    }
                    if let reason = model.disabledReason {
                        Text(reason).font(.caption).foregroundStyle(.secondary)
                    }
                    if let error = model.errorMessage {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .frame(width: 380)
            .frame(maxHeight: .infinity)
            .onChange(of: catalog.selectedModelID) { model.applyDefaults() }
            .toolbar {
                ProfilesMenu(
                    profiles: profiles, workflows: [.textToImage],
                    capabilities: { id in catalog.entries.first { $0.id == id }?.capabilities },
                    apply: { model.apply($0) },
                    makeProfile: { model.makeProfile(named: $0) })
            }

            Divider()

            VStack(spacing: 0) {
                ResultPane(job: model.latestJob(in: jobs))
                Divider()
                QueueView(jobs: jobs)
                    .frame(height: 190)
            }
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Shows the progress or result of one job.
struct ResultPane: View {
    let job: JobSnapshot?

    var body: some View {
        ZStack {
            Rectangle().fill(.background)
            switch job?.state {
            case .none:
                ContentUnavailableView("Brak wyników", systemImage: "photo",
                                       description: Text("Wpisz prompt i kliknij Generuj (⌘↩)."))
            case .completed(let image):
                ThumbnailView(url: image.fileURL, maxPixel: 2048, contentMode: .fit)
                    .padding()
                    .overlay(alignment: .bottomLeading) {
                        Text(String(format: "seed %llu · %.1f s", image.seed, image.elapsedSeconds))
                            .font(.caption).padding(6).background(.thinMaterial, in: .rect(cornerRadius: 6)).padding()
                    }
            case .failed(let message):
                ContentUnavailableView("Błąd", systemImage: "exclamationmark.triangle", description: Text(message))
            case .cancelled:
                ContentUnavailableView("Anulowano", systemImage: "stop.circle")
            case .some:
                if let job { JobStatusView(job: job) }
            }
        }
    }
}

/// Model selector limited to models that support `requiredMode`.
public struct ModelPicker: View {
    @Bindable var catalog: ModelCatalogStore
    let requiredMode: ModeKind?

    public init(catalog: ModelCatalogStore, requiredMode: ModeKind?) {
        self.catalog = catalog
        self.requiredMode = requiredMode
    }

    public var body: some View {
        Picker("Model", selection: Binding(
            get: { catalog.selected?.id ?? "" },
            set: { catalog.selectedModelID = $0 }
        )) {
            ForEach(catalog.entries) { entry in
                let usable = requiredMode.map { entry.capabilities?.supports($0) ?? false } ?? true
                Text(entry.descriptor.name + (entry.installed ? "" : " (niepobrany)"))
                    .tag(entry.id)
                    .disabled(!usable)
            }
        }
    }
}
