import Foundation
@testable import Oops
import OopsCore
import Synchronization
import Testing

@MainActor struct FeatureSelectionTests {
    /// Exactly what 0.1.4 writes: the providers, Fix's choice with each model's settings, and the catalogs.
    private nonisolated static let released: [String: String] = [
        "providers": #"""
        [{"id":"chatgpt","kind":{"chatGPT":{}},"name":"ChatGPT","shownModels":["gpt-6-luna"]},
         {"id":"claude-code","kind":{"claudeCode":{}},"name":"Claude Code","shownModels":["haiku","sonnet"]},
         {"id":"5F0C5A52-7C1E-4B8E-9C1A-2E3D4F5A6B7C","kind":{"api":{"preset":"mistral"}},"name":"Mistral",
          "baseURL":"https://api.mistral.ai/v1","shownModels":["mistral-small-latest"]}]
        """#,
        "modelSelection": #"""
        {"choice":{"providerID":"claude-code","modelID":"sonnet"},
         "settings":{"claude-code/sonnet":{"effort":"high","fast":false},"chatgpt/gpt-6-luna":{"effort":"low","fast":true}}}
        """#,
        "providerCatalogs": #"""
        {"claude-code":[{"id":"haiku","name":"Haiku 5.5","efforts":[{"id":"low","description":"Fast"},{"id":"high","description":"Deep"}]},
                        {"id":"sonnet","name":"Sonnet 5.5","efforts":[{"id":"low","description":"Fast"},{"id":"high","description":"Deep"}]}],
         "5F0C5A52-7C1E-4B8E-9C1A-2E3D4F5A6B7C":[{"id":"mistral-small-latest","name":"mistral-small-latest","efforts":[]}]}
        """#,
    ]
    private static let mistral = ModelSelection.Choice(providerID: "5F0C5A52-7C1E-4B8E-9C1A-2E3D4F5A6B7C", modelID: "mistral-small-latest")

    private final class Suite {
        let name = "oops-feature-selection-" + UUID().uuidString
        let defaults: UserDefaults
        init() throws {
            defaults = try #require(UserDefaults(suiteName: name))
            for (key, value) in FeatureSelectionTests.released { defaults.set(Data(value.utf8), forKey: key) }
        }
        deinit { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        @MainActor func store() -> ProviderStore {
            ProviderStore(chatGPT: ChatGPTAuth(store: NoCredentials(), openBrowser: { _ in }), preview: false, defaults: defaults,
                          writeKey: { _, _ in }, readKey: { _ in "" })
        }
    }

    @Test func `the released format loads Fix's provider, model and effort unchanged`() throws {
        let suite = try Suite()
        let store = suite.store()
        #expect(store.providers.map(\.id) == ["chatgpt", "claude-code", Self.mistral.providerID])
        #expect(store.selection.choice == .init(providerID: "claude-code", modelID: "sonnet"))
        #expect(store.currentSettings == .init(effort: "high", fast: false))
        #expect(store.selection.settings(for: .init(providerID: "chatgpt", modelID: "gpt-6-luna")) == .init(effort: "low", fast: true))
        #expect(store.notice == nil)
        #expect(store.dictateSelection == DictateSelection())
        // Saving back leaves Fix's choice under the same key, readable as before.
        let saved = try #require(suite.defaults.data(forKey: ModelFeature.fix.preferenceKey))
        #expect(try JSONDecoder().decode(ModelSelection.self, from: saved) == store.selection)
    }

    @Test func `Dictate's choice persists beside Fix's without touching it`() throws {
        let suite = try Suite()
        let store = suite.store()
        store.selectDictate(.local("parakeet-unified-en"), languages: nil)
        store.selectDictate(language: "en")
        let reloaded = suite.store()
        #expect(reloaded.dictateSelection == DictateSelection(model: .local("parakeet-unified-en"), language: "en"))
        #expect(reloaded.selection == store.selection)
        #expect(reloaded.currentSettings == .init(effort: "high", fast: false))
    }

    @Test func `capabilities cover shown models and the one-time check runs once`() async throws {
        let suite = try Suite()
        let store = suite.store()
        let shown = store.shownCapabilities
        #expect(shown.count == 4)
        #expect(shown[.init(providerID: "claude-code", modelID: "haiku")]?.capabilities?.voice == false)
        #expect(shown[Self.mistral] == .needsUserAnswer)

        let runs = Mutex(0)
        store.features.probe = { _, _ in runs.withLock { $0 += 1 }; return .notVoice }
        #expect(store.capabilities(Self.mistral) == .needsProbe)
        await store.probeCapabilities(Self.mistral)
        await store.probeCapabilities(Self.mistral)
        #expect(runs.withLock { $0 } == 1)
        #expect(store.capabilities(Self.mistral) == .resolved(ModelCapabilities(text: true, voice: false, source: .probe)))
        // The verdict outlives the launch: a new store neither asks nor checks again.
        let reloaded = suite.store()
        reloaded.features.probe = { _, _ in runs.withLock { $0 += 1 }; return .voice }
        await reloaded.probeCapabilities(Self.mistral)
        #expect(runs.withLock { $0 } == 1)
        #expect(reloaded.capabilities(Self.mistral).capabilities?.source == .probe)
    }

    @Test func `the user's answer settles a model nothing else could`() throws {
        let suite = try Suite()
        let store = suite.store()
        store.answerCapabilities(Self.mistral, voice: false)
        #expect(suite.store().capabilities(Self.mistral) == .resolved(ModelCapabilities(text: true, voice: false, source: .user)))
    }

    @Test func `a provider's voice model isn't offered, and one saved falls back to an installed model`() async throws {
        let suite = try Suite()
        let store = suite.store()
        store.answerCapabilities(Self.mistral, voice: true)
        #expect(store.capabilities(Self.mistral).capabilities?.voice == true)
        let whisper = try #require(SpeechModelCatalog.model(id: "whisper_large_v3_turbo"))
        let local = LocalModels(store: FakeModelStore(installed: [whisper.artifact.fileName]))
        await local.refresh()
        #expect(store.dictateOptions(local).map(\.reference) == [.local(whisper.id)])
        store.selectDictate(.provider(Self.mistral), languages: nil)
        #expect(store.dictateOption(local)?.reference == .local(whisper.id))
        #expect(store.dictationModelPath(local, override: nil) == FakeModelStore.url(whisper.artifact.fileName).path)
        await local.delete(whisper)
        #expect(store.dictationModelPath(local, override: nil) == nil)
    }
}

private final class NoCredentials: ChatGPTStore, Sendable {
    func readProfile() throws -> ChatGPTProfile? { nil }
    func readCredentials() throws -> ChatGPTCredentials? { nil }
    func writeProfile(_ profile: ChatGPTProfile) throws {}
    func writeCredentials(_ credentials: ChatGPTCredentials) throws {}
    func deleteCredentials() throws {}
}
