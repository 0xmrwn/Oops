import Foundation
@testable import Oops
import OopsCore
import Testing

@MainActor struct APIProviderSetupTests {
    private let models = [CatalogModel(id: "embedding", name: "Embedding"), CatalogModel(id: "writer", name: "Writer")]

    private func setup() -> APIProviderSetup {
        APIProviderSetup(discover: { _, _ in models }, correct: { _ in ProviderStep.sampleFixed })
    }

    private func settle(_ setup: APIProviderSetup) async {
        for _ in 0..<1000 {
            if !setup.busy { return }
            await Task.yield()
        }
        Issue.record("Setup did not finish")
    }

    @Test func `keyless local and proof invalidation`() async {
        let setup = setup()
        setup.choose(ProviderPreset(id: "lmstudio"))
        #expect(setup.canConnect)
        setup.connect(); await settle(setup)
        #expect(setup.model == "writer")
        setup.prove(); await settle(setup)
        #expect(setup.passed)
        setup.chooseModel("embedding")
        #expect(!setup.passed)
        setup.edit()
        #expect(setup.models.isEmpty)
        #expect(setup.phase == .credentials)
    }

    @Test func `detected local authentication requires a key without blocking keyless servers`() {
        let setup = setup()
        let local = ProviderPreset(id: "lmstudio")
        setup.choose(local, needsKey: true)
        #expect(!setup.keyOptional)
        #expect(!setup.canConnect)
        setup.changeKey("test-only")
        #expect(setup.canConnect)
        setup.choose(local)
        #expect(setup.keyOptional)
        #expect(setup.canConnect)
    }

    @Test func `cloud needs key and unsafe endpoint never sends it`() {
        var called = false
        let setup = APIProviderSetup(discover: { _, _ in called = true; return models }, correct: { _ in "" })
        setup.choose(ProviderPreset(id: "openai"))
        #expect(!setup.canConnect)
        setup.changeKey("test-only")
        setup.changeEndpoint("http://example.com/v1")
        setup.connect()
        #expect(!called)
        #expect(setup.error != nil)
        setup.changeEndpoint("https://user:password@example.com/v1")
        setup.connect()
        #expect(!called)
    }

    @Test func `back and cancel reject late discovery`() async {
        var finish: CheckedContinuation<[CatalogModel], Never>?
        let setup = APIProviderSetup(discover: { _, _ in await withCheckedContinuation { finish = $0 } }, correct: { _ in "" })
        setup.choose(ProviderPreset(id: "lmstudio"))
        setup.changeKey("test-only")
        setup.connect()
        while finish == nil { await Task.yield() }
        setup.cancel()
        #expect(setup.key == "test-only")
        #expect(setup.phase == .credentials)
        setup.clear()
        finish?.resume(returning: models)
        for _ in 0..<10 { await Task.yield() }
        #expect(setup.models.isEmpty)
        #expect(setup.key.isEmpty)
        #expect(setup.endpoint.isEmpty)
    }

    @Test func `cancelled proof cannot enable Continue`() async {
        var finish: CheckedContinuation<String, Never>?
        let setup = APIProviderSetup(discover: { _, _ in models }, correct: { _ in await withCheckedContinuation { finish = $0 } })
        setup.choose(ProviderPreset(id: "lmstudio"))
        setup.connect(); await settle(setup)
        setup.prove()
        while finish == nil { await Task.yield() }
        setup.cancel()
        #expect(setup.phase == .models)
        finish?.resume(returning: ProviderStep.sampleFixed)
        for _ in 0..<10 { await Task.yield() }
        #expect(!setup.passed)
        #expect(setup.canProve)
    }

    @Test func `text field commits with unchanged values preserve discovery and proof`() async {
        let setup = setup()
        setup.choose(ProviderPreset(id: "lmstudio"))
        setup.connect()
        setup.changeEndpoint(setup.endpoint)
        setup.changeKey(setup.key)
        await settle(setup)
        #expect(setup.connected)
        setup.prove(); await settle(setup)
        setup.changeEndpoint(setup.endpoint)
        setup.chooseModel(setup.model)
        #expect(setup.passed)
    }

    @Test func `authentication failure and retry`() async {
        var attempts = 0
        let setup = APIProviderSetup(discover: { _, _ in
            attempts += 1
            if attempts == 1 { throw CorrectionError.message("The provider rejected the API key.") }
            return models
        }, correct: { _ in throw CorrectionError.message("The API took too long. Try again.") })
        setup.choose(ProviderPreset(id: "lmstudio"))
        setup.connect(); await settle(setup)
        #expect(setup.error == "The provider rejected the API key.")
        setup.connect(); await settle(setup)
        #expect(setup.connected)
        #expect(setup.error == nil)
        setup.prove(); await settle(setup)
        #expect(!setup.passed)
        #expect(setup.error == "The API took too long. Try again.")
        #expect(setup.canProve)
    }

    @Test func `continue saves exact model and preserves settings draft`() async {
        let auth = ChatGPTAuth(store: ChatGPTKeychainStore(), openBrowser: { _ in })
        let store = ProviderStore(chatGPT: auth, preview: true)
        store.startDraft(); store.chooseDraftPreset(ProviderPreset(id: "groq"))
        let settingsDraft = store.draft, previousChoice = store.selection.choice
        let count = store.providers.count
        let setup = setup()
        setup.choose(ProviderPreset(id: "lmstudio"))
        #expect(!setup.commit(to: store))
        setup.connect(); await settle(setup)
        #expect(store.providers.count == count)
        #expect(store.selection.choice == previousChoice)
        setup.prove(); await settle(setup)
        #expect(setup.commit(to: store))
        #expect(store.providers.count == count + 1)
        #expect(store.currentProvider?.baseURL == "http://localhost:1234/v1")
        #expect(store.currentModel?.id == "writer")
        #expect(store.currentProvider?.shownModels == ["writer"])
        #expect(store.draft == settingsDraft)
        #expect(setup.key.isEmpty)
    }
    @Test func `durable commit and keychain failure are transactional`() throws {
        let suite = "oops-onboarding-test-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let auth = ChatGPTAuth(store: ChatGPTKeychainStore(), openBrowser: { _ in })
        var writes: [(String, String)] = []
        let store = ProviderStore(chatGPT: auth, preview: false, defaults: defaults, writeKey: { writes.append(($0, $1)) })
        let preset = try #require(ProviderPreset(id: "mistral"))
        try store.addOnboardingAPI(preset: preset, endpoint: preset.endpoint.absoluteString, key: "test-only", models: models, model: "writer")
        #expect(writes.count == 1)
        #expect(writes[0].1 == store.currentProvider?.id)
        let reloaded = ProviderStore(chatGPT: auth, preview: false, defaults: defaults, writeKey: { _, _ in })
        #expect(reloaded.selection.choice == store.selection.choice)
        #expect(reloaded.currentModel?.id == "writer")
        #expect(reloaded.providers == store.providers)
        let failing = ProviderStore(chatGPT: auth, preview: false, defaults: defaults, writeKey: { _, _ in throw CorrectionError.message("Keychain unavailable") })
        failing.startDraft()
        let before = failing.providers, draft = failing.draft, choice = failing.selection.choice
        #expect(throws: (any Error).self) {
            try failing.addOnboardingAPI(preset: preset, endpoint: preset.endpoint.absoluteString, key: "test-only", models: models, model: "writer")
        }
        #expect(failing.providers == before)
        #expect(failing.draft == draft)
        #expect(failing.selection.choice == choice)
        #expect(!String(decoding: try #require(defaults.data(forKey: "providers")), as: UTF8.self).contains("test-only"))
    }
}
