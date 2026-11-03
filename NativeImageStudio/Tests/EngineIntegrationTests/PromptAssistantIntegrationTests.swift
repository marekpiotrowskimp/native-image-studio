import Application
import Domain
import Foundation
import Infrastructure
import MLXEngine
import PromptAssistant
import Testing

/// Real LLM inference with the prompt assistant. Runs via `scripts/integration-tests.sh` when the
/// model is downloaded (`nis-poc prompt-download`).
enum PromptAssistantGate {
    static func make() -> (MLXPromptAssistant, GenerationCoordinator) {
        let models = ModelRepository()
        let coordinator = GenerationCoordinator(
            registry: EngineRegistry([]), models: models,
            memory: MemoryBudgetManager(probe: DarwinMemoryProbe(gpu: MLXGPUMemory())))
        return (MLXPromptAssistant(coordinator: coordinator), coordinator)
    }

    static var installed: Bool {
        let dir = MLXPromptAssistant.defaultRoot.appendingPathComponent(MLXPromptAssistant.Model.qwen3_8BAbliterated.directoryName)
        return FileManager.default.fileExists(atPath: dir.appendingPathComponent("model.safetensors").path)
    }

    static var enabled: Bool { IntegrationGate.requested && installed }

    static var reason: Comment {
        if !IntegrationGate.requested { return "SKIPPED: LLM inference — run scripts/integration-tests.sh" }
        return "SKIPPED: prompt assistant model not downloaded — run `nis-poc prompt-download`"
    }
}

@Suite("Prompt assistant integration (Qwen3-8B)", .serialized, .enabled(if: PromptAssistantGate.enabled, PromptAssistantGate.reason))
struct PromptAssistantIntegrationTests {
    func draft(_ assistant: MLXPromptAssistant, _ request: PromptDraftRequest) async throws -> (String, [PromptAssistantEvent]) {
        var events: [PromptAssistantEvent] = []
        var text = ""
        for try await event in await assistant.write(request) {
            events.append(event)
            if case .finished(let t) = event { text = t }
        }
        return (text, events)
    }

    @Test func writesEnglishPromptsInEachStyleFromAPolishIdea() async throws {
        let (assistant, _) = PromptAssistantGate.make()
        let idea = "starszy rybak naprawia sieci na molo o świcie, mgła nad wodą"
        for style in PromptStyle.allCases {
            let (text, events) = try await draft(assistant, PromptDraftRequest(idea: idea, style: style))
            #expect(!text.isEmpty, "\(style)")
            #expect(!text.contains("<think>"))
            // Written in English about the requested subject (tag styles say "old man, fishing net").
            #expect(text.lowercased().contains("fish"), "\(style): \(text)")
            #expect(events.contains { if case .partial = $0 { true } else { false } })
            if let budget = PromptCleaner.wordBudget(style) {
                #expect(text.split(separator: " ").count <= budget, "\(style): \(text)")
            }
            switch style {
            case .ponyTags: #expect(text.hasPrefix(PromptInstructions.ponyPrefix + ", "))
            case .booruTags: #expect(text.hasPrefix(PromptInstructions.booruPrefix + ", "))
            case .naturalLanguage, .sdxlPhrases: break
            }
        }
        await assistant.releaseGPU()
    }

    @Test func refiningKeepsTheSubjectAndAppliesTheChange() async throws {
        let (assistant, _) = PromptAssistantGate.make()
        let request = PromptDraftRequest(idea: "zmień porę na noc", currentPrompt: "a red tram on a cobblestone street, autumn afternoon",
                                         style: .naturalLanguage)
        let (text, _) = try await draft(assistant, request)
        let lower = text.lowercased()
        #expect(lower.contains("tram"))
        #expect(lower.contains("night") || lower.contains("evening") || lower.contains("dark"), "\(text)")
        await assistant.releaseGPU()
    }

    @Test func releaseReturnsTheMemory() async throws {
        let (assistant, _) = PromptAssistantGate.make()
        _ = try await draft(assistant, PromptDraftRequest(idea: "kot na parapecie", style: .naturalLanguage))
        #expect(await assistant.isLoaded)
        let loaded = DarwinMemoryProbe.processFootprint().gigabytes
        await assistant.releaseGPU()
        #expect(await !assistant.isLoaded)
        // Measured: ~4.3 GB while loaded, < 0.5 GB once released.
        #expect(DarwinMemoryProbe.processFootprint().gigabytes < loaded - 3)
    }
}
