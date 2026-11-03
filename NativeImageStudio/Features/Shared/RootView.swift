import Infrastructure
import SwiftUI

public enum AppSection: String, CaseIterable, Identifiable, Sendable {
    case generation, editing, gallery, models, benchmarks

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .generation: "Generowanie"
        case .editing: "Edycja zdjęć"
        case .gallery: "Galeria"
        case .models: "Modele"
        case .benchmarks: "Benchmarki"
        }
    }

    var icon: String {
        switch self {
        case .generation: "sparkles"
        case .editing: "wand.and.stars"
        case .gallery: "photo.on.rectangle.angled"
        case .models: "cube.box"
        case .benchmarks: "speedometer"
        }
    }
}

/// Selected sidebar section (observable so tools/menus can drive navigation).
@MainActor
@Observable
public final class AppNavigation {
    public var section: AppSection? = .generation
    public init() {}
}

/// Main window: sidebar + feature screens. Holds no engine knowledge.
public struct RootView: View {
    let generation: GenerationViewModel
    let editing: ImageEditingViewModel
    let jobs: JobsStore
    let catalog: ModelCatalogStore
    let gallery: GalleryStore
    let profiles: ProfilesStore
    let benchmarkLog: BenchmarkLog
    let assistant: PromptAssistantStore
    @Bindable var navigation: AppNavigation

    public init(generation: GenerationViewModel, editing: ImageEditingViewModel, jobs: JobsStore,
                catalog: ModelCatalogStore, gallery: GalleryStore, profiles: ProfilesStore,
                benchmarkLog: BenchmarkLog, assistant: PromptAssistantStore, navigation: AppNavigation) {
        self.navigation = navigation
        self.assistant = assistant
        self.profiles = profiles
        self.benchmarkLog = benchmarkLog
        self.generation = generation
        self.editing = editing
        self.jobs = jobs
        self.catalog = catalog
        self.gallery = gallery
    }

    public var body: some View {
        NavigationSplitView {
            List(AppSection.allCases, selection: $navigation.section) { s in
                Label(s.title, systemImage: s.icon).tag(s)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
            .safeAreaInset(edge: .bottom) {
                if let active = jobs.activeJob {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(active.state.polishLabel).font(.caption)
                        ProgressView(value: active.state.fraction).controlSize(.small)
                        if !jobs.queuedJobs.isEmpty {
                            Text("W kolejce: \(jobs.queuedJobs.count)").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .padding(10)
                }
            }
        } detail: {
            switch navigation.section ?? .generation {
            case .generation: GenerationView(model: generation, jobs: jobs, catalog: catalog, profiles: profiles, assistant: assistant)
            case .editing: ImageEditingView(model: editing, jobs: jobs, catalog: catalog, profiles: profiles)
            case .gallery: GalleryView(store: gallery)
            case .models: ModelLibraryView(catalog: catalog, assistant: assistant)
            case .benchmarks: BenchmarksView(log: benchmarkLog)
            }
        }
        .navigationTitle((navigation.section ?? .generation).title)
        .task {
            jobs.start()
            await catalog.reload()
            await assistant.refresh()
            await profiles.reload()
            generation.applyDefaults()
            editing.applyDefaults()
        }
    }
}
