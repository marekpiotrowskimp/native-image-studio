import Application
import Domain
import Foundation
import Infrastructure
import MLX
import MLXLLM
import MLXLMCommon
import Tokenizers

/// Prompt assistant on a local Qwen3-8B (abliterated) in MLX. Loads on first use, stays loaded
/// for follow-up requests and is released by the coordinator before an image model loads.
/// Load and generation run under `GenerationCoordinator.withExclusiveGPU`, so the LLM never
/// shares unified memory with an image model.
public actor MLXPromptAssistant: PromptWriting, GPUResident {
    public struct Model: Sendable {
        public var name: String
        public var repo: String
        public var revision: String
        public var directoryName: String
        public var downloadSizeBytes: Int64

        /// huihui-ai/Huihui-Qwen3-8B-abliterated-v2 (Apache-2.0) converted to MLX MXFP4 by
        /// mlx-community; revision pinned to the one verified in docs/PROGRESS.md.
        public static let qwen3_8BAbliterated = Model(
            name: "Qwen3-8B Abliterated v2 (MLX MXFP4)",
            repo: "mlx-community/Qwen3-8B-abliterated-v2-mxfp4",
            revision: "0310576b3aa0daf9d8ad6ec370ff2c545ef02194",
            directoryName: "Qwen3-8B-abliterated-v2-mxfp4",
            downloadSizeBytes: 4_366_000_000)
    }

    /// Sampling recommended by the Qwen3 model card for non-thinking mode.
    static let parameters = GenerateParameters(maxTokens: 320, temperature: 0.7, topP: 0.8, topK: 20)

    public static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NativeImageStudio/LLM", isDirectory: true)
    }

    public nonisolated let modelName: String
    public nonisolated let downloadSizeBytes: Int64
    private let model: Model
    private let directory: URL
    private let coordinator: GenerationCoordinator
    private var container: ModelContainer?
    public private(set) var lastLoadSeconds: Double?

    public init(model: Model = .qwen3_8BAbliterated, root: URL = MLXPromptAssistant.defaultRoot,
                coordinator: GenerationCoordinator) {
        self.model = model
        self.modelName = model.name
        self.downloadSizeBytes = model.downloadSizeBytes
        self.directory = root.appendingPathComponent(model.directoryName, isDirectory: true)
        self.coordinator = coordinator
    }

    // MARK: Install

    public func isInstalled() -> Bool {
        let fm = FileManager.default
        return ["config.json", "tokenizer.json", "model.safetensors"].allSatisfy {
            fm.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
    }

    public func install(progress: (@Sendable (Double, String) -> Void)?) async throws {
        try await HuggingFaceDownloader.download(repo: model.repo, revision: model.revision,
                                                 into: directory, progress: progress)
        guard isInstalled() else {
            throw GenerationError.modelNotFound("\(model.name): niekompletne pliki w \(directory.path).")
        }
    }

    public func remove() async throws {
        await releaseGPU()
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    public var isLoaded: Bool { container != nil }

    // MARK: GPUResident

    /// Returns once the weights have actually left the process: the footprint lags the freed MLX
    /// buffers by up to ~2 s (measured: 3.98 GB right after release, 0.09 GB 2 s later), and an
    /// image model loading in that window would briefly need both.
    public func releaseGPU() async {
        guard container != nil else { return }
        let freedBytes = UInt64(max(0, Memory.activeMemory))
        let before = DarwinMemoryProbe.processFootprint()
        container = nil
        Stream.gpu.synchronize()
        Memory.clearCache()
        let target = before - min(before, freedBytes * 3 / 4)
        let deadline = ContinuousClock.now + .seconds(3)
        while DarwinMemoryProbe.processFootprint() > target, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        StageLog.note("prompt assistant released")
    }

    // MARK: Writing

    public func write(_ request: PromptDraftRequest) -> AsyncThrowingStream<PromptAssistantEvent, any Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: PromptAssistantEvent.self)
        let task = Task {
            do {
                let text = try await self.run(request, continuation: continuation)
                continuation.yield(.finished(text))
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { termination in
            if case .cancelled = termination { task.cancel() }
        }
        return stream
    }

    private func run(_ request: PromptDraftRequest,
                     continuation: AsyncThrowingStream<PromptAssistantEvent, any Error>.Continuation) async throws -> String {
        guard isInstalled() else {
            throw GenerationError.modelNotFound("Asystent promptów: model nie jest pobrany. Pobierz go w zakładce Modele.")
        }
        if await coordinator.isBusy { continuation.yield(.waitingForGPU) }
        return try await coordinator.withExclusiveGPU {
            try Task.checkCancellation()
            let container = try await self.loadedContainer(continuation)
            let session = ChatSession(
                container,
                instructions: PromptInstructions.system(for: request.style),
                generateParameters: Self.parameters,
                additionalContext: ["enable_thinking": false])
            var raw = ""
            StageLog.note("prompt assistant: generating (\(request.style.rawValue))")
            for try await chunk in session.streamResponse(to: PromptInstructions.user(for: request)) {
                raw += chunk
                continuation.yield(.partial(PromptCleaner.clean(raw, style: request.style, final: false)))
            }
            try Task.checkCancellation()
            Memory.clearCache()
            StageLog.note("prompt assistant: done, \(raw.count) chars")
            return PromptCleaner.clean(raw, style: request.style)
        }
    }

    private func loadedContainer(_ continuation: AsyncThrowingStream<PromptAssistantEvent, any Error>.Continuation) async throws -> ModelContainer {
        if let container { return container }
        continuation.yield(.loadingModel)
        let start = ContinuousClock.now
        StageLog.note("load prompt assistant: start")
        let loaded = try await LLMModelFactory.shared.loadContainer(from: directory, using: TransformersTokenizerLoader())
        lastLoadSeconds = (ContinuousClock.now - start).seconds
        StageLog.note(String(format: "load prompt assistant: %.2f s", lastLoadSeconds ?? 0))
        container = loaded
        return loaded
    }
}

/// swift-transformers tokenizer behind mlx-swift-lm's `Tokenizer` (what the MLXHuggingFace
/// macros generate, written out to avoid the macro plugin).
struct TransformersTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        TokenizerBridge(try await AutoTokenizer.from(modelFolder: directory))
    }
}

struct TokenizerBridge: MLXLMCommon.Tokenizer {
    let upstream: any Tokenizers.Tokenizer

    init(_ upstream: any Tokenizers.Tokenizer) { self.upstream = upstream }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}
