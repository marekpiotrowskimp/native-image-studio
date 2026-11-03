import Foundation

/// Contract every inference backend implements. Knows nothing about MLX or Core ML types.
///
/// Cancellation contract: when the consumer stops iterating the stream (task
/// cancellation or `onTermination`), the engine must stop at the next safe point
/// (between denoising steps) and finish the stream with `GenerationError.cancelled`.
public protocol ImageGenerationEngine: Sendable {
    var id: String { get }
    var backend: BackendKind { get }
    /// Union of what the engine can do; per-model limits via `capabilities(forModel:)`.
    var capabilities: EngineCapabilities { get }

    /// Capabilities of a specific model served by this engine, or nil if unknown.
    func capabilities(forModel modelID: String) async -> EngineCapabilities?
    /// ID of the currently loaded model.
    func loadedModelID() async -> String?

    func loadModel(id: String) async throws
    func generate(request: GenerationRequest) async throws -> AsyncThrowingStream<GenerationEvent, any Error>
    /// Request a stop. The stream of `requestID` then finishes with
    /// `GenerationError.cancelled` once a safe point is reached.
    func cancel(requestID: UUID) async
    /// Stop generation, release the pipeline, synchronize the GPU and drop caches.
    func unloadModel() async
    /// How intermediate images are reported as `.preview` events (default: none).
    func setLivePreview(_ mode: LivePreviewMode) async
}

/// Something other than an image engine that keeps a model in unified memory (e.g. the
/// prompt assistant's LLM). The coordinator releases it before loading an image model.
public protocol GPUResident: Sendable {
    func releaseGPU() async
}

/// Lifecycle of a queued job: Queued → Loading → Running → Completed | Cancelled | Failed.
public enum JobState: Sendable, Equatable {
    case queued
    case loading
    case running(step: Int, total: Int)
    case completed(GeneratedImage)
    case cancelled
    case failed(String)

    public var isTerminal: Bool {
        switch self {
        case .completed, .cancelled, .failed: true
        default: false
        }
    }

    public var label: String {
        switch self {
        case .queued: "Queued"
        case .loading: "Loading"
        case .running: "Running"
        case .completed: "Completed"
        case .cancelled: "Cancelled"
        case .failed: "Failed"
        }
    }
}

/// Optional engine capability: local weight management (download/check), so the UI can
/// install models without knowing the backend.
public protocol ModelWeightsProvider: Sendable {
    func isInstalled(modelID: String) async -> Bool
    func install(modelID: String, progress: (@Sendable (Double, String) -> Void)?) async throws
    /// Bytes on disk that `remove` would free (0 when not installed).
    func installedSizeBytes(modelID: String) async -> Int64
    /// Deletes the model's own weights (shared components may be kept and are listed in the result).
    func remove(modelID: String) async throws -> [String]
}

/// Recursive on-disk size of a file or directory (allocated bytes).
public func diskUsage(of url: URL) -> Int64 {
    let fm = FileManager.default
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
    guard isDir.boolValue else {
        return Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
    }
    var total: Int64 = 0
    let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
    if let e = fm.enumerator(at: url, includingPropertiesForKeys: keys) {
        for case let f as URL in e {
            let v = try? f.resourceValues(forKeys: Set(keys))
            if v?.isRegularFile == true { total += Int64(v?.totalFileAllocatedSize ?? 0) }
        }
    }
    return total
}
