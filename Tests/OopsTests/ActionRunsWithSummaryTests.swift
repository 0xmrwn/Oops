import Foundation
@testable import Oops
import OopsCore
import Testing

/// What the editor's Runs with row says, resolved the way the run resolves it.
@MainActor struct ActionRunsWithSummaryTests {
    private func store() -> ProviderStore {
        ProviderStore(chatGPT: ChatGPTAuth(store: NoAccount(), openBrowser: { _ in }), preview: true)
    }

    @Test func `same as fix names Fix's model at its lightest level`() {
        #expect(store().runsWithSummary(.sameAsFix).text == "Same as Fix · Haiku 5.5 · Low")
    }

    @Test func `a model no longer switched on follows Fix`() {
        let run = ActionRunsWith(model: .init(choice: .init(providerID: "claude-code", modelID: "opus"), effort: "high"))
        #expect(store().runsWithSummary(run).sameAsFix)
    }

    @Test func `a saved model whose catalog hasn't loaded is named, not called Same as Fix`() {
        let store = store()
        store.setShown("preview-groq", model: "llama", true)
        let run = ActionRunsWith(model: .init(choice: .init(providerID: "preview-groq", modelID: "llama")))
        #expect(store.actionModel(run.model)?.followsFix == false)
        #expect(!store.runsWithSummary(run).sameAsFix)
        #expect(store.runsWithSummary(run).model == ModelSelection.modelName("llama"))
    }

    @Test func `the agent's model falls back to the preferred one`() {
        #expect(store().agentModel(.init(model: "gone"))?.id == "haiku")
    }
}

private final class NoAccount: ChatGPTStore, Sendable {
    func readProfile() throws -> ChatGPTProfile? { nil }
    func readCredentials() throws -> ChatGPTCredentials? { nil }
    func writeProfile(_ profile: ChatGPTProfile) throws {}
    func writeCredentials(_ credentials: ChatGPTCredentials) throws {}
    func deleteCredentials() throws {}
}
