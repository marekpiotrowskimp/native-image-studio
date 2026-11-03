import CoreML
import Domain
import Foundation
import Infrastructure

/// Where a Core ML model's compiled resources live and how to fetch them.
///
/// Core ML resources (`*.mlmodelc`, `vocab.json`, `merges.txt`) are produced offline by
/// Apple's converter (Python is allowed for conversion, never at runtime). The app only
/// downloads already compiled resources.
public enum CoreMLModelLoader {
    /// Files every SDXL resource directory must contain.
    static let requiredSDXL = ["TextEncoder2.mlmodelc", "VAEDecoder.mlmodelc", "vocab.json", "merges.txt"]

    public static var defaultModelsRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NativeImageStudio/CoreMLModels", isDirectory: true)
    }

    public static func resourceDirectory(for d: ModelDescriptor, root: URL = defaultModelsRoot) -> URL {
        if let path = d.backendOptions["resourcePath"], !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        return root.appendingPathComponent(d.id, isDirectory: true)
    }

    public static func isInstalled(_ d: ModelDescriptor, root: URL = defaultModelsRoot) -> Bool {
        let dir = resourceDirectory(for: d, root: root)
        let fm = FileManager.default
        let unet = fm.fileExists(atPath: dir.appendingPathComponent("Unet.mlmodelc").path)
            || fm.fileExists(atPath: dir.appendingPathComponent("UnetChunk1.mlmodelc").path)
        return unet && requiredSDXL.allSatisfy { fm.fileExists(atPath: dir.appendingPathComponent($0).path) }
    }

    public static func hasEncoder(_ d: ModelDescriptor, root: URL = defaultModelsRoot) -> Bool {
        FileManager.default.fileExists(atPath: resourceDirectory(for: d, root: root).appendingPathComponent("VAEEncoder.mlmodelc").path)
    }

    /// Native output size of a converted SDXL UNet: its `sample` input is a fixed
    /// latent [2, 4, H/8, W/8]. Read from the compiled model's metadata.
    public static func nativeResolution(_ d: ModelDescriptor, root: URL = defaultModelsRoot) -> Int? {
        let dir = resourceDirectory(for: d, root: root)
        for name in ["Unet.mlmodelc", "UnetChunk1.mlmodelc"] {
            let url = dir.appendingPathComponent(name).appendingPathComponent("metadata.json")
            guard let data = try? Data(contentsOf: url),
                  let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  let inputs = arr.first?["inputSchema"] as? [[String: Any]],
                  let sample = inputs.first(where: { ($0["name"] as? String) == "sample" }),
                  let shape = sample["shape"] as? String ?? (sample["shape"] as? [Int]).map({ "\($0)" }) else { continue }
            let dims = shape.components(separatedBy: CharacterSet(charactersIn: "[], ")).compactMap(Int.init)
            if dims.count == 4 { return dims[2] * 8 }
        }
        return nil
    }

    public static func computeUnits(_ d: ModelDescriptor) -> MLComputeUnits {
        switch d.backendOptions["computeUnits"] {
        case "cpuAndGPU": .cpuAndGPU
        case "cpuOnly": .cpuOnly
        case "all": .all
        default: .cpuAndNeuralEngine
        }
    }

    // MARK: Download (Hugging Face, compiled resources only)

    /// Downloads every file of `backendOptions["hfRepo"]` (at `hfRevision`, default main)
    /// into the resource directory. Files already present with the expected size are skipped.
    public static func download(_ d: ModelDescriptor, root: URL = defaultModelsRoot,
                                progress: (@Sendable (Double, String) -> Void)?) async throws {
        guard let repo = d.backendOptions["hfRepo"] else {
            throw GenerationError.modelNotFound("\(d.name): brak źródła (hfRepo) w manifeście — skopiuj zasoby Core ML ręcznie.")
        }
        try await HuggingFaceDownloader.download(
            repo: repo, revision: d.backendOptions["hfRevision"] ?? "main",
            into: resourceDirectory(for: d, root: root), progress: progress)
    }
}
