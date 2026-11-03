import Domain
import Foundation
import Observation

/// UI state of the prompt assistant: install state, the idea being turned into a prompt and
/// the streamed draft. The draft only reaches the prompt editor when the user accepts it.
@MainActor
@Observable
public final class PromptAssistantStore {
    public enum Status: Equatable {
        case idle
        case waitingForGPU
        case loadingModel
        case writing
        case failed(String)

        public var isWorking: Bool {
            switch self {
            case .waitingForGPU, .loadingModel, .writing: true
            case .idle, .failed: false
            }
        }

        public var label: String? {
            switch self {
            case .idle: nil
            case .waitingForGPU: "Czekam na zakończenie generowania obrazu…"
            case .loadingModel: "Ładowanie modelu językowego…"
            case .writing: "Piszę prompt…"
            case .failed(let message): message
            }
        }
    }

    public var idea = ""
    public private(set) var draft = ""
    public private(set) var status: Status = .idle
    public private(set) var installed = false
    public private(set) var installProgress: Double?
    public private(set) var installMessage: String?

    private let writer: any PromptWriting
    private var task: Task<Void, Never>?

    public init(writer: any PromptWriting) {
        self.writer = writer
    }

    public var modelName: String { writer.modelName }
    public var downloadSize: String { ByteCountFormatter.string(fromByteCount: writer.downloadSizeBytes, countStyle: .file) }

    public func refresh() async {
        installed = await writer.isInstalled()
    }

    public func install() {
        guard installProgress == nil else { return }
        installProgress = 0
        let writer = self.writer
        Task {
            do {
                try await writer.install { fraction, message in
                    Task { @MainActor in
                        self.installProgress = fraction
                        self.installMessage = message
                    }
                }
                installMessage = nil
            } catch {
                installMessage = userMessage(error)
            }
            installProgress = nil
            await refresh()
        }
    }

    public func remove() {
        let writer = self.writer
        Task {
            stop()
            do { try await writer.remove() } catch { installMessage = userMessage(error) }
            await refresh()
        }
    }

    /// `refining`: rewrite `currentPrompt` (with `idea` as the requested change, if any);
    /// otherwise write a new prompt from `idea` alone.
    public func write(refining currentPrompt: String?, style: PromptStyle) {
        stop()
        let request = PromptDraftRequest(idea: idea, currentPrompt: currentPrompt, style: style)
        draft = ""
        status = .writing
        let writer = self.writer
        task = Task {
            do {
                for try await event in await writer.write(request) {
                    switch event {
                    case .waitingForGPU: status = .waitingForGPU
                    case .loadingModel: status = .loadingModel
                    case .partial(let text):
                        status = .writing
                        draft = text
                    case .finished(let text):
                        draft = text
                        status = .idle
                    }
                }
                if status.isWorking { status = .idle }
            } catch is CancellationError {
                status = .idle
            } catch {
                status = Task.isCancelled ? .idle : .failed(userMessage(error))
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
        if status.isWorking { status = .idle }
    }

    public func discardDraft() {
        draft = ""
    }

    public func canWrite(currentPrompt: String) -> (new: Bool, refine: Bool) {
        let hasIdea = !idea.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasPrompt = !currentPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return (installed && hasIdea, installed && hasPrompt)
    }
}
