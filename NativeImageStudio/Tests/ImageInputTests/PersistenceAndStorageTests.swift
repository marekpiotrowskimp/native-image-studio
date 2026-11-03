import CoreGraphics
import Domain
import Foundation
import Infrastructure
import TestSupport
import Testing

@Suite("Image persistence")
struct ImagePersistenceTests {
    func metadata(for request: GenerationRequest) -> GenerationMetadata {
        GenerationMetadata(request: request, backend: "mlx", inputs: InputProvenance.records(for: request))
    }

    @Test func savesNewFileWithSidecarAndNeverOverwrites() async throws {
        let dir = try FixtureFactory.temporaryDirectory()
        let input = try FixtureFactory.write(FixtureFactory.quadrantImage(width: 32, height: 32),
                                             to: dir.appendingPathComponent("input.png"), type: .png)
        let inputHash = try ImageInputProcessor.sha256(of: input)
        let repo = ImageRepository(outputDirectory: dir.appendingPathComponent("out"))
        let request = TestModels.request(mode: .imageToImage(strength: 0.5),
                                         inputs: [InputImage(sourceURL: input, role: .primary)], batchID: UUID())
        let meta = metadata(for: request)
        let image = FixtureFactory.quadrantImage(width: 16, height: 16)

        let a = try await repo.save(image, metadata: meta, inputs: [input])
        let b = try await repo.save(image, metadata: meta, inputs: [input])
        #expect(a != b)
        #expect(a != input && b != input)
        #expect(FileManager.default.fileExists(atPath: ImageRepository.sidecarURL(for: a).path))
        #expect(try ImageInputProcessor.sha256(of: input) == inputHash)

        let loaded = try await repo.loadMetadata(for: a)
        #expect(loaded.prompt == request.prompt)
        #expect(loaded.seed == request.seed)
        #expect(loaded.batchID == request.batchID)
        #expect(loaded.mode == request.mode)
        #expect(loaded.inputs.first?.sha256 == inputHash)
        #expect(loaded.inputs.first?.role == .primary)

        let entries = await repo.allEntries()
        #expect(entries.count == 2)
    }
}

@Suite("Model storage")
struct ModelStorageTests {
    @Test func bundledKleinManifestLoads() async throws {
        let repo = ModelRepository()
        let klein = try await repo.descriptor(id: "flux2-klein-4b")
        #expect(klein.backend == .mlx)
        #expect(klein.architecture == "flux2")
        #expect(klein.capabilities.contains(.textToImage))
        #expect(klein.maxReferenceImages >= 1)
        #expect(!klein.license.isEmpty)
    }

    @Test func userManifestsOverrideAndValidate() async throws {
        let dir = try FixtureFactory.temporaryDirectory()
        var custom = TestModels.descriptor(id: "flux2-klein-4b", maxReferenceImages: 2)
        custom.name = "Custom Klein"
        try JSONEncoder().encode(custom).write(to: dir.appendingPathComponent("a.json"))
        let repo = ModelRepository(userManifestDirectory: dir)
        #expect(try await repo.descriptor(id: "flux2-klein-4b").name == "Custom Klein")
        await #expect(throws: ModelStorageError.unknownModel("nope")) { try await repo.descriptor(id: "nope") }

        let bad = Data(#"{"id":"x"}"#.utf8)
        #expect(throws: ModelStorageError.self) { try ModelRepository.decodeManifest(bad) }
    }
}

@Suite("Benchmark log")
struct BenchmarkLogTests {
    @Test func appendsAndReadsJSONLines() throws {
        let dir = try FixtureFactory.temporaryDirectory()
        let log = BenchmarkLog(fileURL: dir.appendingPathComponent("b/bench.jsonl"))
        let r = BenchmarkRecord(model: "m", backend: "mlx", mode: "textToImage", inputImageCount: 0, quantization: "int4",
                                width: 1024, height: 1024, steps: 4, seed: 1, coldLoadSeconds: 3.2, generationSeconds: 10,
                                secondsPerStep: 2, peakMemoryGB: 8, footprintGB: 9)
        try log.append(r)
        try log.append(r)
        let all = try log.readAll()
        #expect(all.count == 2)
        #expect(all[0].model == "m" && all[0].coldLoadSeconds == 3.2)
        #expect(r.markdownRow.contains("1024×1024"))
    }
}

@Suite("Gallery folders on disk")
struct GalleryFolderFileTests {
    func saved(_ repo: ImageRepository) async throws -> (URL, GenerationMetadata) {
        let meta = GenerationMetadata(request: TestModels.request(), backend: "mlx", inputs: [])
        return (try await repo.save(FixtureFactory.quadrantImage(width: 8, height: 8), metadata: meta, inputs: []), meta)
    }

    @Test func movesImageWithSidecarIntoFolderAndBack() async throws {
        let dir = try FixtureFactory.temporaryDirectory()
        let repo = ImageRepository(outputDirectory: dir)
        let (url, meta) = try await saved(repo)
        try repo.createFolder("Portrety")
        let moved = try repo.moveImage(at: url, toFolder: "Portrety", createdAt: meta.createdAt)
        #expect(moved.deletingLastPathComponent().lastPathComponent == "Portrety")
        #expect(repo.folderName(of: moved) == "Portrety")
        #expect(repo.folderName(of: url) == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(!FileManager.default.fileExists(atPath: ImageRepository.sidecarURL(for: url).path))
        #expect(try await repo.loadMetadata(for: moved).requestID == meta.requestID)
        // Still found by the disk import.
        #expect(await repo.allEntries().map(\.url.lastPathComponent) == [moved.lastPathComponent])

        let back = try repo.moveImage(at: moved, toFolder: nil, createdAt: meta.createdAt)
        #expect(back.standardizedFileURL == url.standardizedFileURL)
        #expect(repo.folderName(of: back) == nil)
    }

    @Test func moveNeverOverwritesAnExistingFile() async throws {
        let dir = try FixtureFactory.temporaryDirectory()
        let repo = ImageRepository(outputDirectory: dir)
        let (url, meta) = try await saved(repo)
        try repo.createFolder("A")
        let occupied = repo.foldersRoot.appendingPathComponent("A").appendingPathComponent(url.lastPathComponent)
        try Data("other".utf8).write(to: occupied)
        let moved = try repo.moveImage(at: url, toFolder: "A", createdAt: meta.createdAt)
        #expect(moved != occupied)
        #expect(try Data(contentsOf: occupied) == Data("other".utf8))
        #expect(FileManager.default.fileExists(atPath: ImageRepository.sidecarURL(for: moved).path))
    }

    @Test func folderOfPathDoesNotDependOnTheFileExisting() throws {
        let repo = ImageRepository(outputDirectory: URL(fileURLWithPath: "/tmp/nis-none/out", isDirectory: true))
        // Nothing exists on disk; /private/tmp and /tmp are the same place.
        #expect(repo.folderName(of: URL(fileURLWithPath: "/private/tmp/nis-none/out/Foldery/A/x.png")) == "A")
        #expect(repo.folderName(of: URL(fileURLWithPath: "/tmp/nis-none/out/Foldery/A/x.png")) == "A")
        #expect(repo.folderName(of: URL(fileURLWithPath: "/tmp/nis-none/out/2026-10-27/x.png")) == nil)
        #expect(repo.folderName(of: URL(fileURLWithPath: "/tmp/nis-none/out/Foldery/A/B/x.png")) == nil)
    }

    @Test func folderNamesAreValidatedListedAndRenamed() throws {
        let repo = ImageRepository(outputDirectory: try FixtureFactory.temporaryDirectory())
        #expect(ImageRepository.sanitizedFolderName("  Wakacje 2026 ") == "Wakacje 2026")
        #expect(ImageRepository.sanitizedFolderName("a/b") == "a-b")
        #expect(ImageRepository.sanitizedFolderName("   ") == nil)
        #expect(ImageRepository.sanitizedFolderName(".ukryty") == nil)
        try repo.createFolder("b")
        try repo.createFolder("a")
        #expect(throws: GalleryFolderError.alreadyExists("a")) { try repo.createFolder("a") }
        #expect(repo.folders() == ["a", "b"])
        #expect(try repo.renameFolder("a", to: "c") == "c")
        #expect(repo.folders() == ["b", "c"])
    }
}
