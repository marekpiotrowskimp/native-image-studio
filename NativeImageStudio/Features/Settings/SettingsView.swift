import AppKit
import Domain
import Foundation
import Infrastructure
import SwiftUI

/// Persisted user settings (UserDefaults).
public struct AppSettings: Codable, Equatable, Sendable {
    public var outputDirectoryPath: String
    public var memory: MemoryBudgetConfig
    public var progressUpdatesPerSecond: Double
    public var livePreview: LivePreviewMode

    public init(
        outputDirectoryPath: String = ImageRepository.defaultOutputDirectory.path,
        memory: MemoryBudgetConfig = MemoryBudgetConfig(),
        progressUpdatesPerSecond: Double = 4,
        livePreview: LivePreviewMode = .approximate
    ) {
        self.outputDirectoryPath = outputDirectoryPath
        self.memory = memory
        self.progressUpdatesPerSecond = progressUpdatesPerSecond
        self.livePreview = livePreview
    }

    /// Settings saved by an older version lack newer keys; they keep their defaults instead of
    /// failing the whole decode (which would silently reset e.g. the output folder).
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings()
        outputDirectoryPath = try c.decodeIfPresent(String.self, forKey: .outputDirectoryPath) ?? defaults.outputDirectoryPath
        memory = try c.decodeIfPresent(MemoryBudgetConfig.self, forKey: .memory) ?? defaults.memory
        progressUpdatesPerSecond = try c.decodeIfPresent(Double.self, forKey: .progressUpdatesPerSecond)
            ?? defaults.progressUpdatesPerSecond
        livePreview = try c.decodeIfPresent(LivePreviewMode.self, forKey: .livePreview) ?? defaults.livePreview
    }

    static let key = "NativeImageStudio.settings"
    /// Posted after the settings window saved a change.
    public static let didChange = Notification.Name("NativeImageStudio.settingsDidChange")

    public static func load(_ defaults: UserDefaults = .standard) -> AppSettings {
        guard let data = defaults.data(forKey: key),
              let s = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return s
    }

    public func save(_ defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
    }

    public var outputDirectory: URL { URL(fileURLWithPath: outputDirectoryPath, isDirectory: true) }
}

public struct SettingsView: View {
    @State private var settings = AppSettings.load()
    @State private var snapshot: MemorySnapshot?
    private let probe: any SystemMemoryProbe

    public init(probe: any SystemMemoryProbe) {
        self.probe = probe
    }

    public var body: some View {
        Form {
            Section("Wyniki") {
                LabeledContent("Folder") {
                    HStack {
                        Text(settings.outputDirectoryPath).lineLimit(1).truncationMode(.middle)
                        Button("Zmień…") { chooseFolder() }
                    }
                }
                Text("Oryginały nigdy nie są nadpisywane; każdy wynik to nowy plik PNG + metadane JSON.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Pamięć") {
                Slider(value: $settings.memory.maxProcessFractionOfRAM, in: 0.5...0.9, step: 0.05) {
                    Text("Limit procesu: \(Int(settings.memory.maxProcessFractionOfRAM * 100))% RAM")
                }
                Stepper(String(format: "Margines bezpieczeństwa: %.1f GB", settings.memory.safetyMarginGB),
                        value: $settings.memory.safetyMarginGB, in: 0...4, step: 0.5)
                if let s = snapshot {
                    LabeledContent("Proces", value: String(format: "%.2f GB", s.processFootprintBytes.gigabytes))
                    LabeledContent("Dostępne w systemie", value: String(format: "%.2f GB", s.systemAvailableBytes.gigabytes))
                    LabeledContent("Presja / termika", value: "\(s.pressure.rawValue) / \(s.thermal.rawValue)")
                }
            }
            Section("Podgląd w trakcie generowania") {
                Picker("Podgląd", selection: $settings.livePreview) {
                    Text("Przybliżony (każdy krok)").tag(LivePreviewMode.approximate)
                    Text("Pełne dekodowanie (co kilka kroków)").tag(LivePreviewMode.fullDecode)
                    Text("Wyłączony").tag(LivePreviewMode.off)
                }
                Text(settings.livePreview.settingsNote).font(.caption).foregroundStyle(.secondary)
            }
            Section("Interfejs") {
                Stepper("Aktualizacje postępu: \(Int(settings.progressUpdatesPerSecond))/s",
                        value: $settings.progressUpdatesPerSecond, in: 1...10)
                Text("Zmiany folderu i limitów pamięci obowiązują po ponownym uruchomieniu.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .onChange(of: settings) {
            settings.save()
            NotificationCenter.default.post(name: AppSettings.didChange, object: nil)
        }
        .task {
            while !Task.isCancelled {
                snapshot = probe.snapshot()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { settings.outputDirectoryPath = url.path }
    }
}

extension LivePreviewMode {
    var settingsNote: String {
        switch self {
        case .approximate:
            "Rozmyty podgląd przewidywanego obrazu po każdym kroku, wyliczany bez dekodera VAE — praktycznie bez kosztu."
        case .fullDecode:
            "Ostry podgląd przez dekoder VAE ok. 4 razy w trakcie (FLUX.2, modele SDXL; Z-Image pokazuje podgląd przybliżony). Wydłuża generowanie i zwiększa zużycie pamięci."
        case .off:
            "Tylko pasek postępu."
        }
    }
}
