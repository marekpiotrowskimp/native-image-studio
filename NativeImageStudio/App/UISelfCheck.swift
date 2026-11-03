import AppKit
import Domain
import Features
import CoreGraphics
import Darwin
import Foundation

/// Developer self-check (`NIS_SELFCHECK_DIR=<dir>`): drives the real UI end-to-end and
/// renders the app's own window to PNGs (no screen-recording permission needed), then quits.
/// Optional `NIS_SELFCHECK_INPUTS=<a.png>:<b.png>` feeds the editing screen.
@MainActor
enum UISelfCheck {
    static var outputDirectory: URL? {
        ProcessInfo.processInfo.environment["NIS_SELFCHECK_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static func run(_ c: DependencyContainer) async {
        guard let dir = outputDirectory else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var log: [String] = []
        func note(_ s: String) { log.append(s); print("[selfcheck] \(s)") }

        await wait(seconds: 2)
        await c.catalog.reload()
        note("models: \(c.catalog.entries.map { "\($0.id) installed=\($0.installed)" })")
        if let model = ProcessInfo.processInfo.environment["NIS_SELFCHECK_MODEL"] {
            c.catalog.selectedModelID = model
            c.generation.applyDefaults()
            c.editing.applyDefaults()
        }

        // Live preview only (`NIS_SELFCHECK_PREVIEW=1`, use with the NIS_SELFCHECK_GALLERY sandbox):
        // one generation, a snapshot once a preview arrives, then quit.
        if ProcessInfo.processInfo.environment["NIS_SELFCHECK_PREVIEW"] == "1" {
            c.navigation.section = .generation
            c.generation.prompt = "a lighthouse on a cliff at sunset, dramatic sky"
            c.generation.randomizeSeed = false
            c.generation.seed = 42
            if let size = ProcessInfo.processInfo.environment["NIS_SELFCHECK_RESOLUTION"].flatMap(Int.init) {
                c.generation.resolution = size
            }
            await c.generation.generate()
            await waitUntil(timeout: 600) {
                c.generation.latestJob(in: c.jobs).map { ($0.preview?.step ?? 0) >= 2 || $0.state.isTerminal } ?? false
            }
            if let job = c.generation.latestJob(in: c.jobs), let preview = job.preview {
                note("preview: step \(preview.step)/\(preview.totalSteps) \(preview.width)×\(preview.height) approx=\(preview.isApproximate)")
            }
            await snapshot(dir, "p1-generation-preview")
            await waitUntil(timeout: 600) { c.generation.latestJob(in: c.jobs)?.state.isTerminal ?? false }
            note("generation: \(c.generation.latestJob(in: c.jobs)?.state.label ?? "-")")
            await wait(seconds: 1)
            await snapshot(dir, "p2-generation-result")
            try? log.joined(separator: "\n").write(to: dir.appendingPathComponent("selfcheck.log"), atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
            return
        }

        // 1. Generation
        c.navigation.section = .generation
        c.generation.prompt = "a cozy reading nook by a rainy window, warm lamp light, photorealistic"
        c.generation.resolution = c.generation.capabilities?.supportedResolutions.first ?? 512
        c.generation.randomizeSeed = false
        c.generation.seed = 5
        await snapshot(dir, "1-generation-ready")

        // Prompt assistant: idea → draft → editor (the LLM must be released before the image model loads).
        await c.assistant.refresh()
        if c.assistant.installed, let style = c.catalog.selected?.descriptor.effectivePromptStyle {
            c.assistant.idea = "przytulny kącik do czytania przy oknie, za oknem deszcz, ciepła lampa"
            c.assistant.write(refining: nil, style: style)
            await waitUntil(timeout: 120) { !c.assistant.status.isWorking }
            note("assistant: \(c.assistant.status) draft=\(c.assistant.draft)")
            await snapshot(dir, "1b-assistant-draft")
            if !c.assistant.draft.isEmpty {
                c.generation.prompt = c.assistant.draft
                c.assistant.discardDraft()
            }
        }
        if ProcessInfo.processInfo.environment["NIS_SELFCHECK_GALLERY"] != nil {
            await folders(c, dir, note)
            try? log.joined(separator: "\n").write(to: dir.appendingPathComponent("selfcheck.log"), atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
            return
        }
        if ProcessInfo.processInfo.environment["NIS_SELFCHECK_QUICK"] == "1" {
            c.navigation.section = .gallery
            await wait(seconds: 2)
            await snapshot(dir, "6-gallery")
            await viewer(c, dir, note)
            c.navigation.section = .models
            await wait(seconds: 1)
            await snapshot(dir, "7-models")
            NSApp.terminate(nil)
            return
        }
        await c.generation.generate()
        await wait(seconds: 4)
        if c.generation.latestJob(in: c.jobs)?.state == .loading { await snapshot(dir, "2a-generation-loading") }
        await waitUntil(timeout: 300) { c.generation.latestJob(in: c.jobs).map { if case .running(let s, _) = $0.state { s >= 1 } else { false } } ?? false }
        await snapshot(dir, "2-generation-progress")
        await waitUntil(timeout: 300) {
            c.generation.latestJob(in: c.jobs).map { $0.preview != nil || $0.state.isTerminal } ?? true
        }
        if let preview = c.generation.latestJob(in: c.jobs)?.preview {
            note("preview: step \(preview.step)/\(preview.totalSteps) \(preview.width)×\(preview.height) approx=\(preview.isApproximate)")
            await snapshot(dir, "2b-generation-preview")
        }
        await waitUntil(timeout: 300) { c.generation.latestJob(in: c.jobs)?.state.isTerminal ?? false }
        note("generation: \(c.generation.latestJob(in: c.jobs)?.state.label ?? "-")")
        await wait(seconds: 1)
        await snapshot(dir, "3-generation-result")

        // 2. Editing (references)
        let inputs = (ProcessInfo.processInfo.environment["NIS_SELFCHECK_INPUTS"] ?? "")
            .split(separator: ":").map { URL(fileURLWithPath: String($0)) }
        c.navigation.section = .editing
        if !inputs.isEmpty {
            await c.editing.addFiles(inputs)
            c.editing.mode = .references
            c.editing.resolution = 512
            c.editing.prompt = inputs.count > 1 ? "the woman from image 1 wearing the jacket from image 2" : "make it a snowy evening"
            await snapshot(dir, "4-editing-inputs")
            await c.editing.run()
            await waitUntil(timeout: 600) { c.jobs.job(c.editing.lastJobID)?.state.isTerminal ?? false }
            note("edit: \(c.jobs.job(c.editing.lastJobID)?.state.label ?? "-") \(c.editing.errorMessage ?? "")")
            await wait(seconds: 1)
            await snapshot(dir, "5-editing-before-after")

            // Batch: same prompt per photo, shared batch ID.
            c.editing.mode = .batch
            c.editing.strength = 0.75
            c.editing.prompt = "black and white film photo"
            await c.editing.run()
            if let batch = c.editing.lastBatchID {
                await waitUntil(timeout: 600) { c.jobs.batchProgress(batch).isFinished }
                let p = c.jobs.batchProgress(batch)
                note("batch: total=\(p.total) completed=\(p.completed) failed=\(p.failed) cancelled=\(p.cancelled)")
            }
            await wait(seconds: 1)
            await snapshot(dir, "5b-editing-batch")

            // Inpainting with a mask stroke over the upper body.
            if c.editing.availableModes.contains(.inpainting) {
                c.editing.clear()
                await c.editing.addFiles([inputs[0]])
                c.editing.mode = .inpainting
                c.editing.prompt = "a red and white striped t-shirt"
                c.editing.maskStrokes = [MaskStroke(points: [CGPoint(x: 0.42, y: 0.28), CGPoint(x: 0.58, y: 0.28),
                                                             CGPoint(x: 0.58, y: 0.36), CGPoint(x: 0.42, y: 0.36)],
                                                    width: 0.08, erase: false)]
                await snapshot(dir, "5d-inpainting-mask")

                await c.editing.run()
                await waitUntil(timeout: 600) { c.jobs.job(c.editing.lastJobID)?.state.isTerminal ?? false }
                note("inpainting: \(c.jobs.job(c.editing.lastJobID)?.state.label ?? "-") \(c.editing.errorMessage ?? "")")
                await wait(seconds: 1)
                await snapshot(dir, "5e-inpainting-result")
            }
            // Save the current editing settings as a profile and apply it on a fresh view model.
            if let profile = c.editing.makeProfile(named: "Selfcheck inpainting") {
                await c.profiles.save(profile)
                note("profiles: \(c.profiles.profiles.map(\.name))")
            }
        }

        // Stop during generation.
        c.navigation.section = .generation
        c.generation.resolution = c.generation.capabilities?.supportedResolutions.last ?? 1024
        await c.generation.generate()
        await waitUntil(timeout: 120) { c.generation.latestJob(in: c.jobs).map { if case .running(let s, _) = $0.state { s >= 1 } else { false } } ?? false }
        c.generation.stop(jobs: c.jobs)
        await waitUntil(timeout: 120) { c.generation.latestJob(in: c.jobs)?.state.isTerminal ?? false }
        note("stop: \(c.generation.latestJob(in: c.jobs)?.state.label ?? "-")")
        await snapshot(dir, "5c-generation-stopped")

        // 3. Gallery and models
        c.navigation.section = .gallery
        await wait(seconds: 2)
        await snapshot(dir, "6-gallery")
        await viewer(c, dir, note)
        c.navigation.section = .models
        await wait(seconds: 1)
        await snapshot(dir, "7-models")
        c.navigation.section = .benchmarks
        await wait(seconds: 1)
        await snapshot(dir, "8-benchmarks")

        try? log.joined(separator: "\n").write(to: dir.appendingPathComponent("selfcheck.log"), atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }

    /// Gallery folders in the sandbox (`NIS_SELFCHECK_GALLERY`): create, move the two newest
    /// images in, filter, viewer with folder label, delete from the viewer (moves on), rename.
    static func folders(_ c: DependencyContainer, _ dir: URL, _ note: (String) -> Void) async {
        let g = c.gallery
        c.navigation.section = .gallery
        await wait(seconds: 2)
        _ = await g.importFromDisk()
        let items = g.allItems()
        note("sandbox gallery: \(items.count) images")
        guard items.count >= 3 else { return }
        g.createFolder("Wybrane")
        note("move: failures=\(g.move(Array(items.prefix(2)), to: "Wybrane")) folders=\(g.folders)")
        await snapshot(dir, "f1-all-with-folder-bar")
        g.folderFilter = .folder("Wybrane")
        await wait(seconds: 1)
        await snapshot(dir, "f2-folder-filter")
        let inFolder = g.allItems().filter { g.matches($0, .folder("Wybrane")) }
        g.viewerItemID = inFolder.first?.id
        await wait(seconds: 1.5)
        await snapshot(dir, "f3-viewer-in-folder")
        if let first = inFolder.first {
            g.remove([first], mode: .moveFilesToTrash, visibleOrder: inFolder.map(\.id))
            note("viewer after delete: \(g.viewerItemID == inFolder.last?.id ? "next image" : "\(String(describing: g.viewerItemID))")")
            await wait(seconds: 1.5)
            await snapshot(dir, "f4-viewer-after-delete")
        }
        g.viewerItemID = nil
        g.renameFolder("Wybrane", to: "Ulubione")
        note("after rename: in Ulubione=\(g.allItems().filter { g.matches($0, .folder("Ulubione")) }.count)")
        note("renamed: folders=\(g.folders) filter=\(g.folderFilter) error=\(g.folderError ?? "-")")
        await wait(seconds: 1)
        await snapshot(dir, "f5-renamed")
    }

    /// Full-size viewer on the newest image: fitted, 100 %, then the next image (refitted).
    static func viewer(_ c: DependencyContainer, _ dir: URL, _ note: (String) -> Void) async {
        let items = c.gallery.allItems()
        guard let first = items.first else { return }
        c.gallery.viewerItemID = first.id
        await wait(seconds: 1.5)
        note("viewer fit: \(c.gallery.viewerZoom.magnification) \(first.width)x\(first.height)")
        await snapshot(dir, "6b-viewer-fit")
        c.gallery.viewerZoom.actualSize()
        c.gallery.viewerZoom.zoomIn()
        note("viewer zoomed: \(c.gallery.viewerZoom.magnification)")
        await snapshot(dir, "6c-viewer-zoomed")
        if items.count > 1 {
            c.gallery.viewerItemID = items[1].id
            await wait(seconds: 1.5)
            note("viewer next: fitting=\(c.gallery.viewerZoom.isFitting) \(c.gallery.viewerZoom.magnification)")
            await snapshot(dir, "6d-viewer-next")
        }
        c.gallery.viewerItemID = nil
    }

    static func wait(seconds: Double) async {
        try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
    }

    static func waitUntil(timeout: Double, _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while !condition(), ContinuousClock.now < deadline { await wait(seconds: 0.25) }
    }

    /// Captures the app's own main window. An app may capture its own windows without the
    /// screen-recording permission. `CGWindowListCreateImage` is obsoleted in the macOS 15
    /// SDK, so it is resolved dynamically (developer tool only).
    static func snapshot(_ dir: URL, _ name: String) async {
        await wait(seconds: 0.6)
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) else { return }
        typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let handle = dlopen(nil, RTLD_NOW), let sym = dlsym(handle, "CGWindowListCreateImage") else { return }
        let create = unsafeBitCast(sym, to: CreateImage.self)
        // kCGWindowListOptionIncludingWindow = 1 << 3, kCGWindowImageBoundsIgnoreFraming = 1 << 0
        guard let image = create(.null, 1 << 3, UInt32(window.windowNumber), 1 << 0)?.takeRetainedValue() else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
    }
}
