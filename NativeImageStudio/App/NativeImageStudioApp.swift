import AppKit
import Features
import SwiftData
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Also correct when launched as a bare SwiftPM executable.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct NativeImageStudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var container = DependencyContainer()

    var body: some Scene {
        WindowGroup("Native Image Studio") {
            RootView(
                generation: container.generation,
                editing: container.editing,
                jobs: container.jobs,
                catalog: container.catalog,
                gallery: container.gallery,
                profiles: container.profiles,
                benchmarkLog: container.benchmarkLog,
                assistant: container.assistant,
                navigation: container.navigation)
                .frame(minWidth: 1000, minHeight: 680)
                .task { await UISelfCheck.run(container) }
        }
        .defaultSize(width: 1280, height: 820)
        .modelContainer(container.gallery.container)

        Settings {
            SettingsView(probe: container.probe)
        }
    }
}
