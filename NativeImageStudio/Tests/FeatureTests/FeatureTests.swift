import Application
import Domain
import Features
import Foundation
import Infrastructure
import TestSupport
import Testing

@MainActor
struct FeatureRig {
    let services: AppServices
    let catalog: ModelCatalogStore
    let engine: MockEngine
    let dir: URL

    init(capabilities: EngineCapabilities = MockEngine.defaultCapabilities) async throws {
        dir = try FixtureFactory.temporaryDirectory()
        engine = MockEngine(capabilities: capabilities, outputDirectory: dir)
        let models = ModelRepository(builtIn: [TestModels.descriptor()])
        let registry = EngineRegistry([engine])
        let memory = MemoryBudgetManager(probe: StaticMemoryProbe.gb())
        let coordinator = GenerationCoordinator(registry: registry, models: models, memory: memory, maxUpdatesPerSecond: 1000)
        services = AppServices(
            coordinator: coordinator, batches: BatchCoordinator(coordinator: coordinator),
            registry: registry, models: models, images: ImageRepository(outputDirectory: dir.appendingPathComponent("out")),
            memory: memory)
        catalog = ModelCatalogStore(services: services)
        await catalog.reload()
    }

    func photo(_ name: String, width: Int = 300, height: Int = 200, orientation: Int? = nil) throws -> URL {
        try FixtureFactory.write(FixtureFactory.quadrantImage(width: width, height: height),
                                 to: dir.appendingPathComponent("\(name).jpg"), type: .jpeg, orientation: orientation)
    }
}

@Suite("Image editing view model")
@MainActor
struct ImageEditingViewModelTests {
    @Test func inputsAreNumberedAndReorderable() async throws {
        let rig = try await FeatureRig()
        let vm = ImageEditingViewModel(services: rig.services, catalog: rig.catalog)
        let urls = try (0..<3).map { try rig.photo("p\($0)") }
        await vm.addFiles(urls)
        #expect(vm.inputs.map(\.url) == urls)
        #expect(vm.number(of: vm.inputs[2].id) == 3)

        let third = vm.inputs[2].id
        vm.shift(third, by: -1)
        #expect(vm.number(of: third) == 2)
        vm.move(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        #expect(vm.inputs.last?.url == urls[0])
        vm.remove(third)
        #expect(vm.inputs.count == 2)
        #expect(vm.number(of: third) == nil)
    }

    @Test func rejectsUnsupportedFilesAndDuplicates() async throws {
        let rig = try await FeatureRig()
        let vm = ImageEditingViewModel(services: rig.services, catalog: rig.catalog)
        let good = try rig.photo("ok")
        let text = rig.dir.appendingPathComponent("notes.txt")
        try Data("x".utf8).write(to: text)
        await vm.addFiles([good, text, good])
        #expect(vm.inputs.count == 1)
        #expect(vm.rejectedFiles == ["notes.txt"])
    }

    @Test func availableModesFollowCapabilities() async throws {
        var caps = MockEngine.defaultCapabilities
        caps.supportedModes = [.textToImage, .referenceEdit]
        let rig = try await FeatureRig(capabilities: caps)
        let vm = ImageEditingViewModel(services: rig.services, catalog: rig.catalog)
        // No imageToImage → no transform; batch falls back to reference edit per photo.
        #expect(vm.availableModes == [.references, .batch])

        caps.supportedModes = [.textToImage]
        let t2iOnly = try await FeatureRig(capabilities: caps)
        #expect(ImageEditingViewModel(services: t2iOnly.services, catalog: t2iOnly.catalog).availableModes.isEmpty)
    }

    @Test func referenceLimitComesFromModel() async throws {
        let rig = try await FeatureRig()
        let vm = ImageEditingViewModel(services: rig.services, catalog: rig.catalog)
        vm.mode = .references
        vm.prompt = "combine"
        await vm.addFiles(try (0..<4).map { try rig.photo("r\($0)") })
        #expect(vm.maxInputs == 3)
        #expect(vm.problem?.contains("maksymalnie 3") == true)
        #expect(!vm.canRun)
        vm.remove(vm.inputs[3].id)
        #expect(vm.canRun)
    }

    @Test func outputFollowsFirstImageAspect() async throws {
        let rig = try await FeatureRig()
        let vm = ImageEditingViewModel(services: rig.services, catalog: rig.catalog)
        vm.resolution = 1024
        // EXIF 6: stored 300×200 landscape, displayed 200×300 portrait.
        await vm.addFiles([try rig.photo("portrait", orientation: 6), try rig.photo("land")])
        #expect(vm.outputSize.height > vm.outputSize.width)
        #expect(vm.outputSize.width % 32 == 0)
        vm.aspect = .square
        #expect(vm.outputSize == PixelSize(width: 1024, height: 1024))
    }

    @Test func transformSubmitsSingleImageWithStrength() async throws {
        let rig = try await FeatureRig()
        let vm = ImageEditingViewModel(services: rig.services, catalog: rig.catalog)
        vm.mode = .transform
        vm.strength = 0.35
        vm.prompt = "film look"
        await vm.addFiles([try rig.photo("a")])
        let request = try #require(vm.makeRequest())
        #expect(request.mode == .imageToImage(strength: 0.35))
        #expect(request.inputImages.count == 1 && request.inputImages[0].role == .primary)
        await vm.run()
        let id = try #require(vm.lastJobID)
        if case .completed = await rig.services.coordinator.waitForCompletion(id) {} else { Issue.record("should complete") }
    }

    @Test func batchCreatesOneJobPerPhotoWithSharedID() async throws {
        let rig = try await FeatureRig()
        let vm = ImageEditingViewModel(services: rig.services, catalog: rig.catalog)
        vm.mode = .batch
        vm.prompt = "warm light"
        await vm.addFiles([try rig.photo("a"), try rig.photo("b", width: 200, height: 300), try rig.photo("c")])
        await vm.run()
        let batch = try #require(vm.lastBatchID)
        let progress = await rig.services.batches.waitForBatch(batch)
        #expect(progress.completed == 3)
        let jobs = await rig.services.coordinator.jobs(inBatch: batch)
        #expect(Set(jobs.map(\.request.prompt)) == ["warm light"])
        // Each photo keeps its own aspect ratio.
        #expect(jobs.contains { $0.request.height > $0.request.width })
        #expect(jobs.contains { $0.request.width > $0.request.height })
    }
}

@Suite("Generation view model")
@MainActor
struct GenerationViewModelTests {
    @Test func requestsUseSettingsAndSeeds() async throws {
        let rig = try await FeatureRig()
        let vm = GenerationViewModel(services: rig.services, catalog: rig.catalog)
        vm.prompt = "a fox"
        vm.aspect = .landscape3x2
        vm.resolution = 512
        vm.randomizeSeed = false
        vm.seed = 10
        vm.count = 3
        let requests = vm.makeRequests()
        #expect(requests.map(\.seed) == [10, 11, 12])
        #expect(requests.allSatisfy { $0.width > $0.height && $0.width % 32 == 0 })
        #expect(vm.canGenerate)
        vm.prompt = " "
        #expect(!vm.canGenerate)
        #expect(vm.disabledReason == "Wpisz prompt.")
    }

    @Test func generateAndStop() async throws {
        let rig = try await FeatureRig()
        let jobs = JobsStore(services: rig.services)
        let vm = GenerationViewModel(services: rig.services, catalog: rig.catalog)
        vm.prompt = "a fox"
        vm.steps = 40
        vm.count = 2
        await vm.generate()
        #expect(vm.submittedJobIDs.count == 2)
        let ids = vm.submittedJobIDs
        // Stop cancels both (queued immediately, running at the next step boundary).
        for id in ids { await rig.services.coordinator.cancel(id) }
        for id in ids { #expect(await rig.services.coordinator.waitForCompletion(id) == .cancelled) }
        _ = jobs
    }
}

@Suite("Jobs store")
@MainActor
struct JobsStoreTests {
    @Test func mirrorsCoordinatorAndReportsCompletion() async throws {
        let rig = try await FeatureRig()
        let jobs = JobsStore(services: rig.services)
        var completed: [UUID] = []
        jobs.onCompleted = { completed.append($0.metadata.requestID) }
        jobs.start()
        try await Task.sleep(for: .milliseconds(20))
        let id = try await rig.services.coordinator.submit(TestModels.request())
        _ = await rig.services.coordinator.waitForCompletion(id)
        for _ in 0..<100 where completed.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(completed == [id])
        if case .completed = jobs.job(id)?.state {} else { Issue.record("store should mirror completion") }
        jobs.clearFinished()
        #expect(jobs.jobs.isEmpty)
        jobs.stop()
    }
}

@Suite("Gallery store")
@MainActor
struct GalleryStoreTests {
    @Test func addsDeduplicatesAndLinksInputs() throws {
        let dir = try FixtureFactory.temporaryDirectory()
        let store = GalleryStore(container: try GalleryStore.makeContainer(inMemory: true),
                                 images: ImageRepository(outputDirectory: dir))
        let batch = UUID()
        let req = TestModels.request(mode: .imageToImage(strength: 0.4),
                                     inputs: [InputImage(sourceURL: URL(fileURLWithPath: "/in/a.jpg"), role: .primary)],
                                     batchID: batch)
        let meta = GenerationMetadata(request: req, backend: "mlx",
                                      inputs: [.init(path: "/in/a.jpg", sha256: "abc", role: .primary)])
        let image = GeneratedImage(fileURL: dir.appendingPathComponent("o.png"), seed: 42, elapsedSeconds: 3, metadata: meta)
        store.add(image)
        store.add(image)
        let all = store.allItems()
        #expect(all.count == 1)
        #expect(all[0].inputPaths == ["/in/a.jpg"])
        #expect(all[0].inputHashes == ["abc"])
        #expect(abs((all[0].strength ?? 0) - 0.4) < 1e-6)
        #expect(all[0].seedText == "42")
        #expect(store.items(inBatch: batch).count == 1)
    }

    @Test func importsSidecarsFromDisk() async throws {
        let dir = try FixtureFactory.temporaryDirectory()
        let repo = ImageRepository(outputDirectory: dir)
        let meta = GenerationMetadata(request: TestModels.request(), backend: "mlx", inputs: [])
        _ = try await repo.save(FixtureFactory.quadrantImage(width: 8, height: 8), metadata: meta, inputs: [])
        let store = GalleryStore(container: try GalleryStore.makeContainer(inMemory: true), images: repo)
        #expect(await store.importFromDisk() == 1)
        #expect(await store.importFromDisk() == 0)
    }
}

@Suite("Gallery multi-selection removal")
@MainActor
struct GalleryRemovalTests {
    /// Stand-in for the Trash: deletes instead of polluting the user's Trash.
    static let fakeTrash: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }

    func makeItems(_ n: Int, store: GalleryStore, repo: ImageRepository, input: URL) async throws -> [URL] {
        var urls: [URL] = []
        for i in 0..<n {
            let req = TestModels.request(mode: .imageToImage(strength: 0.5),
                                         inputs: [InputImage(sourceURL: input, role: .primary)], prompt: "p\(i)")
            let meta = GenerationMetadata(request: req, backend: "mlx", inputs: InputProvenance.records(for: req))
            let url = try await repo.save(FixtureFactory.quadrantImage(width: 8, height: 8), metadata: meta, inputs: [input])
            store.add(GeneratedImage(fileURL: url, seed: 1, elapsedSeconds: 1, metadata: meta))
            urls.append(url)
        }
        return urls
    }

    @Test func trashRemovesFilesButNeverInputs() async throws {
        let dir = try FixtureFactory.temporaryDirectory()
        let input = try FixtureFactory.write(FixtureFactory.quadrantImage(width: 8, height: 8),
                                             to: dir.appendingPathComponent("input.png"), type: .png)
        let repo = ImageRepository(outputDirectory: dir.appendingPathComponent("out"))
        let store = GalleryStore(container: try GalleryStore.makeContainer(inMemory: true), images: repo, trash: Self.fakeTrash)
        let urls = try await makeItems(3, store: store, repo: repo, input: input)
        let chosen = Array(store.allItems().prefix(2))
        #expect(store.remove(chosen, mode: .moveFilesToTrash) == 0)
        #expect(store.allItems().count == 1)
        #expect(urls.filter { FileManager.default.fileExists(atPath: $0.path) }.count == 1)
        #expect(FileManager.default.fileExists(atPath: input.path))
        // Trashed files are gone from disk, so a re-import does not resurrect them.
        #expect(await store.importFromDisk() == 0)
    }

    @Test func hideKeepsFilesAndSurvivesReimport() async throws {
        let dir = try FixtureFactory.temporaryDirectory()
        let input = try FixtureFactory.write(FixtureFactory.quadrantImage(width: 8, height: 8),
                                             to: dir.appendingPathComponent("input.png"), type: .png)
        let repo = ImageRepository(outputDirectory: dir.appendingPathComponent("out"))
        let store = GalleryStore(container: try GalleryStore.makeContainer(inMemory: true), images: repo)
        let urls = try await makeItems(2, store: store, repo: repo, input: input)
        store.remove(store.allItems(), mode: .hideOnly)
        #expect(store.allItems().isEmpty)
        #expect(urls.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        #expect(await store.importFromDisk() == 0)
        #expect(store.allItems().isEmpty)
    }

    @Test func rangeSelection() {
        let ids = ["a", "b", "c", "d", "e"]
        #expect(GalleryStore.range(from: "b", to: "d", in: ids) == ["b", "c", "d"])
        #expect(GalleryStore.range(from: "d", to: "b", in: ids) == ["b", "c", "d"])
        #expect(GalleryStore.range(from: "x", to: "c", in: ids) == ["c"])
    }

    @Test func viewerNavigationStopsAtBothEnds() {
        let ids = ["a", "b", "c"]
        #expect(GalleryStore.neighbor(of: "b", offset: 1, in: ids) == "c")
        #expect(GalleryStore.neighbor(of: "b", offset: -1, in: ids) == "a")
        #expect(GalleryStore.neighbor(of: "c", offset: 1, in: ids) == nil)
        #expect(GalleryStore.neighbor(of: "a", offset: -1, in: ids) == nil)
        #expect(GalleryStore.neighbor(of: "x", offset: 1, in: ids) == nil)
    }
}

@Suite("Gallery folders")
@MainActor
struct GalleryFolderTests {
    func rig(_ n: Int) async throws -> (GalleryStore, ImageRepository, URL) {
        let dir = try FixtureFactory.temporaryDirectory()
        let input = try FixtureFactory.write(FixtureFactory.quadrantImage(width: 8, height: 8),
                                             to: dir.appendingPathComponent("input.png"), type: .png)
        let repo = ImageRepository(outputDirectory: dir.appendingPathComponent("out"))
        let store = GalleryStore(container: try GalleryStore.makeContainer(inMemory: true), images: repo,
                                 trash: GalleryRemovalTests.fakeTrash)
        _ = try await GalleryRemovalTests().makeItems(n, store: store, repo: repo, input: input)
        return (store, repo, input)
    }

    @Test func movingSelectionIntoFolderFiltersAndCounts() async throws {
        let (store, _, input) = try await rig(3)
        #expect(store.createFolder("Portrety") == "Portrety")
        #expect(store.folders == ["Portrety"])
        let chosen = Array(store.allItems().prefix(2))
        #expect(store.move(chosen, to: "Portrety") == 0)
        let all = store.allItems()
        #expect(all.filter { store.matches($0, .folder("Portrety")) }.count == 2)
        #expect(all.filter { store.matches($0, .unfiled) }.count == 1)
        #expect(all.filter { store.matches($0, .all) }.count == 3)
        #expect(store.counts(in: all) == ["Portrety": 2, nil: 1])
        #expect(chosen.allSatisfy { FileManager.default.fileExists(atPath: $0.filePath) })
        #expect(FileManager.default.fileExists(atPath: input.path))
        // Moving files must not create duplicates on the next disk import.
        #expect(await store.importFromDisk() == 0)
        #expect(store.allItems().count == 3)
    }

    @Test func renameKeepsImagesInTheFolder() async throws {
        let (store, _, _) = try await rig(2)
        store.createFolder("A")
        store.move(store.allItems(), to: "A")
        store.folderFilter = .folder("A")
        store.renameFolder("A", to: "B")
        #expect(store.folders == ["B"])
        #expect(store.folderFilter == .folder("B"))
        #expect(store.allItems().allSatisfy { store.folder(of: $0) == "B" && FileManager.default.fileExists(atPath: $0.filePath) })
        store.renameFolder("B", to: "   ")
        #expect(store.folderError != nil)
        #expect(store.folders == ["B"])
    }

    @Test func deletingFolderReturnsImagesToTheGallery() async throws {
        let (store, _, _) = try await rig(2)
        store.createFolder("Tmp")
        store.move(store.allItems(), to: "Tmp")
        store.folderFilter = .folder("Tmp")
        store.deleteFolder("Tmp")
        #expect(store.folders.isEmpty)
        #expect(store.folderFilter == .all)
        #expect(store.allItems().count == 2)
        #expect(store.allItems().allSatisfy { store.folder(of: $0) == nil && FileManager.default.fileExists(atPath: $0.filePath) })
    }

    @Test func deletingTheViewedImageMovesTheViewerOn() async throws {
        let (store, _, _) = try await rig(3)
        let order = store.allItems().map(\.id)
        let items = store.allItems()
        store.viewerItemID = order[1]
        // The view passes the images it shows now, as after each deletion.
        store.remove([items[1]], mode: .moveFilesToTrash, visibleOrder: store.allItems().map(\.id))
        #expect(store.viewerItemID == order[2])
        store.remove([items[2]], mode: .moveFilesToTrash, visibleOrder: store.allItems().map(\.id))
        #expect(store.viewerItemID == order[0])
        store.remove([items[0]], mode: .moveFilesToTrash, visibleOrder: store.allItems().map(\.id))
        #expect(store.viewerItemID == nil)
        #expect(store.allItems().isEmpty)
    }

    @Test func importFollowsFilesMovedInFinder() async throws {
        let (store, repo, _) = try await rig(1)
        let item = try #require(store.allItems().first)
        try repo.createFolder("Finder")
        let moved = try repo.moveImage(at: item.fileURL, toFolder: "Finder", createdAt: item.createdAt)
        #expect(await store.importFromDisk() == 0)
        // Same file; the disk scan reports /private/var where the temp URL says /var.
        #expect(item.fileURL.resolvingSymlinksInPath() == moved.resolvingSymlinksInPath())
        #expect(store.folders == ["Finder"])
    }
}

@Suite("Image viewer zoom")
struct ZoomMathTests {
    @Test func fitShowsTheWholeImage() {
        // Wide image in a tall viewport: width decides.
        #expect(ZoomMath.fit(image: CGSize(width: 2000, height: 1000), in: CGSize(width: 1000, height: 1000)) == 0.5)
        // Small image is enlarged up to the viewport.
        #expect(ZoomMath.fit(image: CGSize(width: 512, height: 512), in: CGSize(width: 1024, height: 768)) == 1.5)
        #expect(ZoomMath.fit(image: .zero, in: CGSize(width: 100, height: 100)) == 1)
        #expect(ZoomMath.fit(image: CGSize(width: 10, height: 10), in: CGSize(width: 10_000, height: 10_000)) == ZoomMath.maxMagnification)
    }

    @Test func stepsMoveBetweenPresetsAndClamp() {
        #expect(ZoomMath.step(from: 1, zoomIn: true) == 1.5)
        #expect(ZoomMath.step(from: 1, zoomIn: false) == 0.75)
        #expect(ZoomMath.step(from: 0.6, zoomIn: true) == 0.67)
        #expect(ZoomMath.step(from: 8, zoomIn: true) == ZoomMath.maxMagnification)
        #expect(ZoomMath.step(from: 0.1, zoomIn: false) == ZoomMath.minMagnification)
    }

    @Test func doubleClickTogglesBetweenFitAndActualSize() {
        #expect(ZoomMath.toggleTarget(current: 0.6, fitting: true) == 1)
        #expect(ZoomMath.toggleTarget(current: 1.5, fitting: true) == 3)
        #expect(ZoomMath.toggleTarget(current: 1, fitting: false) == nil)
    }
}
