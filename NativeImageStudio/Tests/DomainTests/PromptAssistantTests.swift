import Domain
import Foundation
import TestSupport
import Testing

@Suite("Prompt assistant (text logic)")
struct PromptAssistantTests {
    @Test func styleFollowsManifestThenArchitecture() {
        #expect(TestModels.descriptor().effectivePromptStyle == .naturalLanguage)
        var sdxl = TestModels.descriptor(id: "sdxl", backend: .coreml)
        sdxl.architecture = "sdxl"
        #expect(sdxl.effectivePromptStyle == .sdxlPhrases)
        sdxl.promptStyle = .ponyTags
        #expect(sdxl.effectivePromptStyle == .ponyTags)
    }

    @Test func manifestWithoutPromptStyleStillDecodes() throws {
        let json = try JSONEncoder().encode(TestModels.descriptor())
        var object = try #require(JSONSerialization.jsonObject(with: json) as? [String: Any])
        object.removeValue(forKey: "promptStyle")
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(try JSONDecoder().decode(ModelDescriptor.self, from: data).promptStyle == nil)
    }

    @Test func systemPromptCarriesStyleRules() {
        #expect(PromptInstructions.system(for: .ponyTags).contains(PromptInstructions.ponyPrefix))
        #expect(PromptInstructions.system(for: .booruTags).contains(PromptInstructions.booruPrefix))
        #expect(PromptInstructions.system(for: .sdxlPhrases).contains("75 tokens"))
        for style in PromptStyle.allCases {
            let s = PromptInstructions.system(for: style)
            #expect(s.contains("English") && s.contains("adult"))
        }
    }

    @Test func userMessageCoversCreateRefineAndChange() {
        let create = PromptInstructions.user(for: .init(idea: "kot na parapecie", style: .naturalLanguage))
        #expect(create == "Scene idea: kot na parapecie")
        let refine = PromptInstructions.user(for: .init(idea: " ", currentPrompt: "a cat", style: .naturalLanguage))
        #expect(refine.hasPrefix("Rewrite and enrich") && refine.hasSuffix("a cat"))
        let change = PromptInstructions.user(for: .init(idea: "make it night", currentPrompt: "a cat", style: .naturalLanguage))
        #expect(change.contains("a cat") && change.hasSuffix("make it night"))
    }

    @Test func cleanerStripsThinkingLabelsQuotesAndNewlines() {
        let raw = "<think>\n\n</think>\n\nPrompt: \"A woman on a pier,\nat dawn\""
        #expect(PromptCleaner.clean(raw, style: .naturalLanguage) == "A woman on a pier, at dawn")
        // Unterminated reasoning while streaming shows nothing yet.
        #expect(PromptCleaner.clean("<think>planning the scene", style: .naturalLanguage, final: false).isEmpty)
    }

    @Test func tagStylesGetTheirPrefixOnlyWhenFinished() {
        let pony = PromptCleaner.clean("source_anime, 1girl, meadow", style: .ponyTags)
        #expect(pony == "\(PromptInstructions.ponyPrefix), source_anime, 1girl, meadow")
        let already = "\(PromptInstructions.booruPrefix), 1girl"
        #expect(PromptCleaner.clean(already, style: .booruTags) == already)
        #expect(PromptCleaner.clean("score_9, sc", style: .ponyTags, final: false) == "score_9, sc")
        #expect(PromptCleaner.clean("a cat", style: .sdxlPhrases) == "a cat")
    }

    // Real outputs of the model before the instructions were tightened (docs/PROGRESS.md).
    @Test func tagPromptsAreTidied() {
        let pony = "\(PromptInstructions.ponyPrefix) source_anime, woman, rain, no text or logos."
        #expect(PromptCleaner.clean(pony, style: .ponyTags)
                == "\(PromptInstructions.ponyPrefix), source_anime, woman, rain, no text or logos")
        let booru = "\(PromptInstructions.booruPrefix), 1girl, rain, low angle, 50 words"
        #expect(PromptCleaner.clean(booru, style: .booruTags) == "\(PromptInstructions.booruPrefix), 1girl, rain, low angle")
    }

    @Test func clipStylesAreCutAtAPhraseBoundary() {
        let phrases = (1...40).map { "phrase number \($0)" }.joined(separator: ", ")  // 120 words
        let cut = PromptCleaner.clean(phrases, style: .sdxlPhrases)
        #expect(cut.split(separator: " ").count <= 55)
        #expect(cut.hasPrefix("phrase number 1,") && cut.hasSuffix("phrase number 18"))
        let long = Array(repeating: "word", count: 150).joined(separator: " ")
        #expect(PromptCleaner.clean(long, style: .naturalLanguage) == long)
    }
}
