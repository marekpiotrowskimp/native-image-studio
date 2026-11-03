import Flux2Core
import FluxTextEncoders
import Foundation
import Synchronization

/// Where Flux2Core / FluxTextEncoders keep downloaded weights.
///
/// Upstream defaults to `~/Library/Caches/models`, which macOS and cleanup tools treat as
/// disposable — gigabytes of weights vanished that way once. The app stores them in
/// Application Support instead (`NIS_MLX_MODELS_DIR` overrides it, e.g. to reuse an
/// existing cache).
public enum MLXModelStorage {
    private static let configured = Mutex(false)

    public static var defaultDirectory: URL {
        if let custom = ProcessInfo.processInfo.environment["NIS_MLX_MODELS_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NativeImageStudio/MLXModels/models", isDirectory: true)
    }

    /// Idempotent; must run before any Flux2Core download or path lookup.
    public static func configure(directory: URL = defaultDirectory) {
        configured.withLock { done in
            guard !done else { return }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            ModelRegistry.customModelsDirectory = directory
            TextEncoderModelDownloader.customModelsDirectory = directory
            TextEncoderModelDownloader.reconfigureHubApi()
            done = true
        }
    }
}
