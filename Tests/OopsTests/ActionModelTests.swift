import Foundation
@testable import Oops
import OopsCore
import Synchronization
import Testing

/// The model an action runs on: its own while it is switched on, else Fix's at its lightest effort.
@MainActor struct ActionModelTests {
    @Test func `same as Fix runs Fix's model at its lightest effort`() throws {
        let fixture = try Fixture()
        fixture.store.select(effort: "medium")
        let target = try #require(fixture.store.actionModel(.init()))
        #expect(target.choice == .init(providerID: fixture.primary, modelID: "a"))
        #expect(target.settings.effort == "low")
    }

    @Test func `a chosen model runs at its own effort`() throws {
        let fixture = try Fixture()
        let choice = ModelSelection.Choice(providerID: fixture.secondary, modelID: "a")
        let target = try #require(fixture.store.actionModel(.init(choice: choice, effort: "medium")))
        #expect(target.choice == choice)
        #expect(target.settings.effort == "medium")
    }

    @Test func `an effort the model lacks moves to the nearest`() throws {
        let fixture = try Fixture()
        let choice = ModelSelection.Choice(providerID: fixture.secondary, modelID: "a")
        #expect(fixture.store.actionModel(.init(choice: choice, effort: "high"))?.settings.effort == "medium")
    }

    @Test func `a model with no efforts sends none`() throws {
        let fixture = try Fixture()
        let choice = ModelSelection.Choice(providerID: fixture.primary, modelID: "b")
        #expect(fixture.store.actionModel(.init(choice: choice, effort: "high"))?.settings.effort == nil)
    }

    @Test func `a switched-off model falls back to Same as Fix`() throws {
        let fixture = try Fixture()
        let choice = ModelSelection.Choice(providerID: fixture.primary, modelID: "b")
        fixture.store.setShown(fixture.primary, model: "b", false)
        let target = try #require(fixture.store.actionModel(.init(choice: choice, effort: "high")))
        #expect(target.choice == .init(providerID: fixture.primary, modelID: "a"))
        #expect(target.settings.effort == "low")
    }

    @Test func `a chosen model runs on its provider before any catalog has loaded`() throws {
        let store = try Bare().store
        let chosen = ModelSelection.Choice(providerID: "other", modelID: "x")
        let target = try #require(store.actionModel(.init(choice: chosen, effort: "high")))
        #expect(target.choice == chosen)
        #expect(target.settings.effort == "high")
    }

    @Test func `a model no longer switched on, or a missing provider, falls back to Same as Fix`() throws {
        let store = try Bare().store
        for chosen in [ModelSelection.Choice(providerID: "other", modelID: "gone"), .init(providerID: "ghost", modelID: "x")] {
            #expect(store.actionModel(.init(choice: chosen, effort: "high"))?.choice == .init(providerID: "fix", modelID: "m"))
        }
    }

    @Test func `no provider fails pointing to Providers`() throws {
        let suite = "oops-action-model-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        // A store that has been through setup and holds no provider; a fresh one detects Claude Code and ChatGPT.
        defaults.set(try JSONEncoder().encode([Provider]()), forKey: "providers")
        defaults.set(try JSONEncoder().encode(ModelSelection()), forKey: "modelSelection")
        let store = ProviderStore(chatGPT: ChatGPTAuth(store: NoCredentials(), openBrowser: { _ in }), preview: false, defaults: defaults,
                                  writeKey: { _, _ in }, readKey: { _ in "" }, makeBackend: { _, _, _ in Silent() })
        #expect(store.actionModel(.init()) == nil)
        #expect(throws: ActionFailure.noModel) { try store.actionBackend(.init()) }
    }

    @Test func `the backend is built at the resolved settings`() throws {
        let fixture = try Fixture()
        _ = try fixture.store.actionBackend(.init())
        let built = try #require(fixture.built.value.last)
        #expect(built.effort == "low")
        #expect(!built.fast)
    }

    @MainActor private final class Fixture {
        let built = Built()
        let store: ProviderStore
        let primary: String, secondary: String
        private let defaults: UserDefaults
        private let suite = "oops-action-model-" + UUID().uuidString

        init() throws {
            let models = try ChatGPTModels.decode(Data(#"{"models":[{"slug":"a","display_name":"A","visibility":"list","supported_reasoning_levels":[{"effort":"low"},{"effort":"medium"}],"service_tiers":[{"id":"priority","name":"Fast"}]}]}"#.utf8))
                .map(CatalogModel.init) + [CatalogModel(id: "b", name: "B")]
            defaults = try #require(UserDefaults(suiteName: suite))
            let built = built
            store = ProviderStore(chatGPT: ChatGPTAuth(store: NoCredentials(), openBrowser: { _ in }), preview: false, defaults: defaults,
                                  writeKey: { _, _ in }, readKey: { _ in "synthetic-key" }, makeBackend: { _, _, settings in
                                      built.append(settings)
                                      return Silent()
                                  })
            store.startDraft()
            let first = try #require(store.draft).id
            try store.addDraft(id: first, name: "Synthetic A", endpoint: "https://a.invalid/v1", key: "synthetic-key", models: models)
            store.setShown(first, model: "a", true); store.setShown(first, model: "b", true)
            store.startDraft()
            let second = try #require(store.draft).id
            try store.addDraft(id: second, name: "Synthetic B", endpoint: "https://b.invalid/v1", key: "synthetic-key", models: models)
            store.setShown(second, model: "a", true)
            primary = first; secondary = second
            store.select(.init(providerID: first, modelID: "a"))
        }

        deinit { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    }
}

/// Two providers saved with their switched-on models and no catalog loaded.
@MainActor private final class Bare {
    let store: ProviderStore
    private let suite = "oops-action-bare-" + UUID().uuidString
    private let defaults: UserDefaults
    init() throws {
        defaults = try #require(UserDefaults(suiteName: suite))
        let fix = Provider(id: "fix", kind: .api(preset: nil), name: "Fix", baseURL: "http://127.0.0.1:1/v1", shownModels: ["m"])
        let other = Provider(id: "other", kind: .api(preset: nil), name: "Other", baseURL: "http://127.0.0.1:2/v1", shownModels: ["x"])
        defaults.set(try JSONEncoder().encode([fix, other]), forKey: "providers")
        defaults.set(try JSONEncoder().encode(ModelSelection(choice: .init(providerID: "fix", modelID: "m"))), forKey: "modelSelection")
        store = ProviderStore(chatGPT: ChatGPTAuth(store: NoCredentials(), openBrowser: { _ in }), preview: false, defaults: defaults,
                              writeKey: { _, _ in }, readKey: { _ in "synthetic-key" }, makeBackend: { _, _, _ in Silent() })
    }
    deinit { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
}

private final class Built: Sendable {
    private let settings = Mutex<[ModelSelection.Settings]>([])
    var value: [ModelSelection.Settings] { settings.withLock { $0 } }
    func append(_ new: ModelSelection.Settings) { settings.withLock { $0.append(new) } }
}

private struct Silent: CorrectionBackend {
    func complete(_ text: String, instructions: String, deadline: Duration) async throws -> String { #"{"text":""}"# }
}

private final class NoCredentials: ChatGPTStore, Sendable {
    func readProfile() throws -> ChatGPTProfile? { nil }
    func readCredentials() throws -> ChatGPTCredentials? { nil }
    func writeProfile(_ profile: ChatGPTProfile) throws {}
    func writeCredentials(_ credentials: ChatGPTCredentials) throws {}
    func deleteCredentials() throws {}
}
