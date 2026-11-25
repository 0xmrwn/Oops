import Foundation
@testable import Oops
import OopsCore
import Testing

/// OpenAI's live transcription as a Dictate model: offered with a key, gone without one.
@MainActor struct DictateOpenAITests {
    private final class Keys { var values: [String: String] = [:]; var reads = 0 }

    private let parakeet = SpeechModelCatalog.model(id: "parakeet_unified_en")!
    private let keys = Keys()
    private let suite = "oops-dictate-openai-" + UUID().uuidString

    private func make(key: String?, openAI: Bool = true) async throws -> (ProviderStore, LocalModels) {
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let keys = keys
        let store = ProviderStore(chatGPT: ChatGPTAuth(store: NoChatGPTCredentials(), openBrowser: { _ in }), preview: false,
                                  defaults: defaults, writeKey: { keys.values[$1] = $0 }, readKey: { keys.reads += 1; return keys.values[$0] ?? "" })
        if openAI {
            let preset = try #require(ProviderPreset(id: "openai"))
            try store.addOnboardingAPI(preset: preset, endpoint: preset.endpoint.absoluteString, key: key ?? "",
                                       models: [CatalogModel(id: "gpt-5", name: "GPT-5")], model: "gpt-5")
        }
        let local = LocalModels(store: FakeModelStore(installed: [parakeet.artifact.fileName]))
        await local.refresh()
        return (store, local)
    }

    @Test func `without a key OpenAI is not offered`() async throws {
        for openAI in [false, true] {
            let (store, local) = try await make(key: nil, openAI: openAI)
            #expect(store.dictateOptions(local).map(\.reference) == [.local(parakeet.id)])
            #expect(store.dictationHostedEngine(local) == nil)
        }
    }

    @Test func `with a key OpenAI is offered as a live model`() async throws {
        let (store, local) = try await make(key: "test-key")
        let options = store.dictateOptions(local)
        #expect(options.count == 2)
        let option = try #require(options.last)
        #expect(option.reference == store.openAIDictateReference)
        #expect(option.name == "GPT-Live-Transcribe")
        #expect(option.streams)
        #expect(option.languages.first == SpeechLanguage.auto && option.languages.contains("fr"))
        #expect(option.languages.allSatisfy { $0 == SpeechLanguage.auto || $0.count == 2 })
    }

    @Test func `choosing OpenAI gives a hosted engine and no model path`() async throws {
        let (store, local) = try await make(key: "test-key")
        #expect(store.dictationHostedEngine(local) == nil)
        store.chooseDictateModel(.local(parakeet.id))
        #expect(store.dictationHostedEngine(local) == nil)
        #expect(store.dictationModelPath(local, override: nil) != nil)
        store.chooseDictateModel(try #require(store.openAIDictateReference))
        #expect(store.dictationHostedEngine(local) is OpenAIRealtimeEngine)
        #expect(store.dictationModelPath(local, override: nil) == nil)
        #expect(store.dictateOption(local)?.name == "GPT-Live-Transcribe")
    }

    @Test func `removing the key falls back to the first local model`() async throws {
        let (store, local) = try await make(key: "test-key")
        store.chooseDictateModel(try #require(store.openAIDictateReference))
        keys.values.removeAll()
        #expect(store.dictationHostedEngine(local) == nil)
        #expect(store.dictateOptions(local).map(\.reference) == [.local(parakeet.id)])
        #expect(store.dictationModelPath(local, override: nil) == FakeModelStore.url(parakeet.artifact.fileName).path)
    }

    @Test func `OpenAI gets the chosen language and the vocabulary as keywords`() async throws {
        let (store, local) = try await make(key: "test-key")
        store.chooseDictateModel(try #require(store.openAIDictateReference))
        let entries = [VocabularyEntry(term: "Ghostty"), VocabularyEntry(term: "Oops")]
        #expect(store.dictationLanguageHint(local, override: nil) == nil)
        #expect(store.dictationCleanupLanguage(local, override: nil) == nil)
        store.chooseDictateLanguage("fr")
        #expect(store.dictationLanguageHint(local, override: nil) == "fr")
        #expect(store.dictationCleanupLanguage(local, override: nil) == "fr")
        #expect(store.dictationVocabulary(local, override: nil, entries: entries) == .openAIKeywords(["Ghostty", "Oops"]))
        #expect(store.dictationVocabulary(local, override: nil, entries: []) == nil)
    }

    @Test func `speech-only is dictation's OpenAI key with no model on, and reads no key`() async throws {
        let (store, _) = try await make(key: "test-key")
        let id = try #require(store.openAITranscriptionProvider?.id)
        store.chooseDictateModel(try #require(store.openAIDictateReference))
        #expect(store.speechOnlyID == nil) // Fix still uses one of its models.
        store.setShown(id, model: "gpt-5", false)
        let reads = keys.reads
        #expect(store.speechOnlyID == id)
        #expect(keys.reads == reads)
        store.chooseDictateModel(.local(parakeet.id))
        #expect(store.speechOnlyID == nil)
    }

    @Test func `without a key nothing is speech-only`() async throws {
        let (store, _) = try await make(key: nil)
        #expect(store.speechOnlyID == nil)
    }
}
