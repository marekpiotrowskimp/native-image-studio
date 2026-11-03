import Application
import Domain
import SwiftUI
import UniformTypeIdentifiers

public struct ImageEditingView: View {
    @Bindable var model: ImageEditingViewModel
    let jobs: JobsStore
    let catalog: ModelCatalogStore
    let profiles: ProfilesStore
    @State private var importing = false
    @State private var dropTargeted = false

    public init(model: ImageEditingViewModel, jobs: JobsStore, catalog: ModelCatalogStore, profiles: ProfilesStore) {
        self.model = model
        self.jobs = jobs
        self.catalog = catalog
        self.profiles = profiles
    }

    public var body: some View {
        HStack(spacing: 0) {
            Form {
                Section("Tryb") {
                    ModelPicker(catalog: catalog, requiredMode: nil)
                    Picker("Tryb edycji", selection: $model.mode) {
                        ForEach(EditMode.allCases) { mode in
                            Text(mode.label).tag(mode).disabled(!model.availableModes.contains(mode))
                        }
                    }
                    .pickerStyle(.segmented)
                    Text(modeHelp).font(.caption).foregroundStyle(.secondary)
                    if model.mode == .transform || model.mode == .batch, model.availableModes.contains(.transform) {
                        VStack(alignment: .leading) {
                            HStack {
                                Text("Siła zmiany")
                                Slider(value: $model.strength, in: 0.05...1, step: 0.05)
                                Text(String(format: "%.2f", model.strength)).monospacedDigit().frame(width: 36)
                            }
                            Text("Przy \(model.steps) krokach siła działa skokowo (co 1/\(model.steps)). 1.0 = tylko warunkowanie obrazem.")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                Section("Prompt") {
                    TextEditor(text: $model.prompt)
                        .frame(minHeight: 90)
                        .accessibilityLabel("Opis efektu")
                    if model.mode == .references && model.inputs.count > 1 {
                        Text("Odwołuj się do zdjęć jako „obraz 1”, „obraz 2”…").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if model.capabilities?.supportsLoRA == true {
                    Section("Adaptery LoRA") { LoRAEditor(loras: $model.loras) }
                }
                Section("Wynik") {
                    if model.capabilities.map({ $0.minDimension < $0.maxDimension }) ?? true {
                        Picker("Proporcje", selection: $model.aspect) {
                            ForEach(AspectPreset.allCases) { Text($0.label).tag($0) }
                        }
                    }
                    Picker("Dopasowanie", selection: $model.resizeMode) {
                        Text("Przytnij").tag(ResizeMode.crop)
                        Text("Dopasuj").tag(ResizeMode.fit)
                        Text("Dopełnij").tag(ResizeMode.pad)
                    }
                    Picker("Rozdzielczość", selection: $model.resolution) {
                        ForEach(model.capabilities?.supportedResolutions ?? [1024], id: \.self) { Text("\($0) px").tag($0) }
                    }
                    LabeledContent("Rozmiar", value: "\(model.outputSize.width) × \(model.outputSize.height)")
                    Stepper("Kroki: \(model.steps)", value: $model.steps, in: model.capabilities?.stepRange ?? 1...50)
                    Toggle("Losowy seed", isOn: $model.randomizeSeed)
                    if !model.randomizeSeed {
                        TextField("Seed", value: $model.seed, format: .number.grouping(.never))
                    }
                }
                Section {
                    HStack {
                        Button {
                            Task { await model.run() }
                        } label: {
                            Label(model.mode == .batch ? "Przetwórz partię (\(model.inputs.count))" : "Edytuj", systemImage: "wand.and.stars")
                        }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(!model.canRun)
                        stopButton
                    }
                    if let problem = model.problem { Text(problem).font(.caption).foregroundStyle(.secondary) }
                    if let error = model.errorMessage { Text(error).font(.caption).foregroundStyle(.red) }
                }
            }
            .formStyle(.grouped)
            .frame(width: 380)
            .frame(maxHeight: .infinity)
            .onChange(of: catalog.selectedModelID) { model.applyDefaults() }
            .toolbar {
                ProfilesMenu(
                    profiles: profiles, workflows: [.transform, .references, .batch, .inpainting],
                    capabilities: { id in catalog.entries.first { $0.id == id }?.capabilities },
                    apply: { model.apply($0) },
                    makeProfile: { model.makeProfile(named: $0) })
            }

            Divider()

            VStack(spacing: 0) {
                inputStrip
                Divider()
                resultArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: ImageEditingViewModel.acceptedTypes, allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { Task { await model.addFiles(urls) } }
        }
    }

    private var modeHelp: String {
        switch model.mode {
        case .transform: "Jedno zdjęcie przekształcone wg promptu."
        case .references: "1–\(model.capabilities?.maxReferenceImages ?? 1) zdjęć jako referencje → jeden nowy obraz."
        case .batch: "Ten sam prompt osobno dla każdego zdjęcia."
        case .inpainting: "Zamaluj obszar na zdjęciu; tylko on zostanie wygenerowany na nowo."
        }
    }

    @ViewBuilder private var stopButton: some View {
        if let batch = model.lastBatchID, !jobs.batchProgress(batch).isFinished {
            Button(role: .cancel) { model.cancelBatch(jobs: jobs) } label: { Label("Anuluj partię", systemImage: "stop.fill") }
        } else if let id = model.lastJobID, let job = jobs.job(id), !job.state.isTerminal {
            Button(role: .cancel) { jobs.cancel(id) } label: { Label("Stop", systemImage: "stop.fill") }
                .keyboardShortcut(".", modifiers: .command)
        }
    }

    // MARK: Inputs

    private var inputStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Zdjęcia wejściowe").font(.headline)
                if let max = model.maxInputs { Text("(\(model.inputs.count)/\(max))").foregroundStyle(.secondary) }
                Spacer()
                Button { importing = true } label: { Image(systemName: "plus") }
                    .help("Dodaj zdjęcia…")
                if !model.inputs.isEmpty {
                    Button { model.clear() } label: { Image(systemName: "trash") }
                        .help("Usuń wszystkie zdjęcia")
                }
            }
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(model.inputs) { input in
                        InputThumb(input: input, number: model.number(of: input.id) ?? 0,
                                   excluded: model.maxInputs.map { (model.number(of: input.id) ?? 0) > $0 } ?? false,
                                   onLeft: { model.shift(input.id, by: -1) },
                                   onRight: { model.shift(input.id, by: 1) },
                                   onRemove: { model.remove(input.id) })
                    }
                    if model.inputs.isEmpty {
                        Text("Przeciągnij tu zdjęcia (JPEG, PNG, HEIC, TIFF) lub kliknij Dodaj…")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 120)
                    }
                }
                .padding(.vertical, 4)
            }
            if !model.rejectedFiles.isEmpty {
                Text("Pominięto (nieobsługiwany format): \(model.rejectedFiles.joined(separator: ", "))")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(10)
        .background(dropTargeted ? Color.accentColor.opacity(0.12) : .clear)
        .dropDestination(for: URL.self) { urls, _ in
            Task { await model.addFiles(urls) }
            return true
        } isTargeted: { dropTargeted = $0 }
    }

    // MARK: Results

    @ViewBuilder private var resultArea: some View {
        if model.showsMaskEditor, let first = model.inputs.first {
            MaskEditorView(imageURL: first.url, imageAspect: CGFloat(first.size.aspectRatio), strokes: $model.maskStrokes)
                .padding()
        } else if let batch = model.lastBatchID {
            BatchResultsView(batchID: batch, jobs: jobs)
        } else if let id = model.lastJobID, let job = jobs.job(id) {
            switch job.state {
            case .completed(let image):
                if let before = job.request.primaryImage?.sourceURL {
                    BeforeAfterView(before: before, after: image.fileURL)
                        .padding()
                        .overlay(alignment: .bottomTrailing) {
                            if job.request.mode.kind == .inpainting {
                                Button("Popraw maskę") { model.backToMask() }.padding()
                            }
                        }
                } else {
                    ThumbnailView(url: image.fileURL, maxPixel: 2048, contentMode: .fit)
                }
            case .failed(let message):
                ContentUnavailableView("Błąd", systemImage: "exclamationmark.triangle", description: Text(message))
            case .cancelled:
                ContentUnavailableView("Anulowano", systemImage: "stop.circle")
            default:
                JobStatusView(job: job)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            ContentUnavailableView("Podgląd przed/po", systemImage: "rectangle.split.2x1",
                                   description: Text("Wynik edycji pojawi się tutaj."))
        }
    }
}

struct InputThumb: View {
    let input: EditInput
    let number: Int
    let excluded: Bool
    let onLeft: () -> Void
    let onRight: () -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            ThumbnailView(url: input.url, maxPixel: 240)
                .frame(width: 110, height: 110)
                .clipShape(.rect(cornerRadius: 8))
                .overlay(alignment: .topLeading) {
                    Text("\(number)")
                        .font(.caption.bold()).foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.accentColor, in: .capsule).padding(4)
                }
                .overlay(alignment: .topTrailing) {
                    Button(action: onRemove) { Image(systemName: "xmark.circle.fill").symbolRenderingMode(.hierarchical) }
                        .buttonStyle(.plain).padding(4).help("Usuń")
                }
                .opacity(excluded ? 0.4 : 1)
            HStack(spacing: 2) {
                Button(action: onLeft) { Image(systemName: "chevron.left") }.buttonStyle(.borderless).help("Przesuń w lewo")
                Text("obraz \(number)").font(.caption2).foregroundStyle(.secondary)
                Button(action: onRight) { Image(systemName: "chevron.right") }.buttonStyle(.borderless).help("Przesuń w prawo")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Obraz \(number), \(input.url.lastPathComponent)")
    }
}

/// Before/after comparison with a draggable divider. All drawing happens inside the
/// image's fitted rect, so the divider, the reveal edge and the drag position coincide.
public struct BeforeAfterView: View {
    let before: URL
    let after: URL
    @State private var split: CGFloat = 0.5
    @State private var aspect: CGFloat?

    public init(before: URL, after: URL) {
        self.before = before
        self.after = after
    }

    public var body: some View {
        GeometryReader { geo in
            let rect = FitGeometry.fittedRect(aspect: aspect ?? 1, in: geo.size)
            ZStack(alignment: .topLeading) {
                ThumbnailView(url: before, maxPixel: 2048, contentMode: .fill)
                    .frame(width: rect.width, height: rect.height)
                    .clipped()
                ThumbnailView(url: after, maxPixel: 2048, contentMode: .fill)
                    .frame(width: rect.width, height: rect.height)
                    .clipped()
                    .mask(alignment: .leading) {
                        Rectangle().frame(width: rect.width * split)
                    }
                Rectangle().fill(.white).frame(width: 2, height: rect.height).shadow(radius: 2)
                    .offset(x: rect.width * split - 1)
                HStack {
                    Text("PO")
                    Spacer()
                    Text("PRZED")
                }
                .font(.caption.bold())
                .foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(.black.opacity(0.35), in: .capsule)
                .padding(8)
                .frame(width: rect.width)
            }
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            // The gesture covers the whole container and maps the pointer into the image rect,
            // so dragging works anywhere (also over the side margins) and stays aligned.
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local).onChanged { v in
                split = FitGeometry.fraction(ofX: v.location.x, in: rect)
            })
            .accessibilityElement()
            .accessibilityLabel("Porównanie przed i po")
            .accessibilityValue("\(Int(split * 100)) procent wyniku")
            .accessibilityAdjustableAction { direction in
                split = min(1, max(0, split + (direction == .increment ? 0.1 : -0.1)))
            }
        }
        .task(id: after) { aspect = FitGeometry.aspectRatio(of: after) ?? FitGeometry.aspectRatio(of: before) }
    }
}

struct BatchResultsView: View {
    let batchID: UUID
    let jobs: JobsStore

    var body: some View {
        let progress = jobs.batchProgress(batchID)
        let members = jobs.sortedJobs.filter { $0.batchID == batchID }.reversed()
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Partia: \(progress.finished)/\(progress.total)").font(.headline)
                Spacer(minLength: 8)
                Text("gotowe \(progress.completed) · błędy \(progress.failed) · anulowane \(progress.cancelled)")
                    .monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
            }
            ProgressView(value: progress.fractionComplete)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                    ForEach(Array(members)) { job in
                        VStack(spacing: 4) {
                            if case .completed(let image) = job.state {
                                ThumbnailView(url: image.fileURL, maxPixel: 300)
                            } else if let input = job.request.primaryImage {
                                ThumbnailView(url: input.sourceURL, maxPixel: 300).opacity(0.35)
                            }
                            Text(job.state.polishLabel).font(.caption2).foregroundStyle(.secondary)
                        }
                        .frame(height: 170)
                        .clipShape(.rect(cornerRadius: 6))
                    }
                }
            }
        }
        .padding()
    }
}
