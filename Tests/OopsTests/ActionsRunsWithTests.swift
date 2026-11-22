import Foundation
@testable import Oops
import OopsCore
import Testing

/// What Runs with offers, and that choosing for an action never reaches Fix.
@MainActor struct ActionsRunsWithTests {
    private static let mistral = ModelSelection.Choice(providerID: "preview-mistral", modelID: "mistral-small-latest")

    /// A store with defaults of its own, removed with the test.
    private final class Suite {
        let name = "oops-runs-with-" + UUID().uuidString
        let defaults: UserDefaults
        init() { defaults = UserDefaults(suiteName: name) ?? .standard }
        deinit { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        @MainActor func store(preview: Bool = true) -> ProviderStore {
            ProviderStore(chatGPT: ChatGPTAuth(store: NoAccount(), openBrowser: { _ in }), preview: preview, defaults: defaults,
                          writeKey: { _, _ in }, readKey: { _ in "" })
        }
    }

    @Test func `action groups offer only text models`() {
        let suite = Suite(), store = suite.store()
        #expect(store.actionGroups.flatMap(\.models).contains { $0.id == Self.mistral.modelID })
        store.answerCapabilities(Self.mistral, voice: true)
        #expect(!store.actionGroups.flatMap(\.models).contains { $0.id == Self.mistral.modelID })
        #expect(store.pickerGroups.flatMap(\.models).contains { $0.id == Self.mistral.modelID })
    }

    @Test func `agent problem follows Claude Code's state`() {
        let suite = Suite()
        #expect(suite.store().agentProblem == nil)
        #expect(suite.store(preview: false).agentProblem == "Not set up")
    }

    @Test func `an action needs a provider not while Fix's model can run it`() {
        let suite = Suite()
        #expect(!suite.store().actionNeedsProvider)
        let empty = suite.store(preview: false)
        #expect(!empty.actionNeedsProvider) // Fix's own model is something to fall back on, while its provider works.
        #expect(empty.actionGroups.isEmpty)
    }

    @Test func `switching kind keeps both sides`() {
        var run = ActionRunsWith(kind: .model, model: .init(choice: Self.mistral, effort: "high"))
        run.agent = .init(model: "sonnet", effort: "medium", searchWeb: false, runCommands: true, usesSetup: true)
        let both = run
        run.kind = .agent
        run.kind = .model
        #expect(run == both)
        #expect(run.model.choice == Self.mistral)
        #expect(run.agent.runCommands && run.agent.usesSetup && !run.agent.searchWeb)
    }

    @Test func `Fix's choice is untouched by the list`() {
        let suite = Suite(), store = suite.store()
        let before = store.selection
        _ = ModelSearch.filter(store.pickerGroups, query: "son") { $0.name }
        _ = ModelSearch.filter(store.actionGroups, query: "") { $0.name }
        #expect(store.selection == before)
    }
}

private final class NoAccount: ChatGPTStore, Sendable {
    func readProfile() throws -> ChatGPTProfile? { nil }
    func readCredentials() throws -> ChatGPTCredentials? { nil }
    func writeProfile(_ profile: ChatGPTProfile) throws {}
    func writeCredentials(_ credentials: ChatGPTCredentials) throws {}
    func deleteCredentials() throws {}
}
