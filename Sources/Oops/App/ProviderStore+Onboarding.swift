import Foundation
import OopsCore

/// What onboarding's Provider step saves on Continue: the provider it proved, with the model it proved,
/// chosen as if picked in General.
extension ProviderStore {
    /// Whether the chosen provider is known to answer now (signed in, or connected), not merely
    /// configured: a fresh install's ChatGPT choice is there before anyone signs in.
    var selectedIsReady: Bool {
        guard let id = selection.choice?.providerID, case .ready? = health[id] else { return false }
        return true
    }

    /// The model onboarding proved, chosen at once: the choice holds until Claude Code's model list
    /// arrives with its sign-in check, which then shows that model.
    func useClaudeCode() {
        _ = addClaudeCode()
        select(.init(providerID: "claude-code", modelID: ModelSelection.preferredClaude[0]))
    }

    func useChatGPT() {
        select(.init(providerID: "chatgpt", modelID: provider("chatgpt")?.shownModels.first ?? ModelSelection.preferredChatGPT[0]))
    }

    /// Save the exact proven model through the same transaction Settings uses. Its unfinished page
    /// belongs to Settings, so preserve it while committing onboarding's independent draft.
    func addOnboardingAPI(preset: ProviderPreset?, endpoint: String, key: String, models: [CatalogModel], model: String) throws {
        let previousDraft = draft, previousPage = openProvider
        defer { draft = previousDraft; openProvider = previousPage }
        startDraft(); chooseDraftPreset(preset)
        guard let pending = draft else { return }
        let name = preset == nil ? URL(string: endpoint)?.host ?? "API provider" : pending.name
        try addDraft(id: pending.id, name: name, endpoint: endpoint, key: key, models: models)
        setShown(pending.id, model: model, true)
        select(.init(providerID: pending.id, modelID: model))
    }

    /// A server on this Mac, added as its preset with no key unless it is already in the list.
    func useLocal(_ preset: ProviderPreset, model: String, models: [CatalogModel]) throws {
        var id = providers.first { $0.kind == .api(preset: preset.id) && $0.baseURL == preset.endpoint.absoluteString }?.id
        if id == nil {
            startDraft(); chooseDraftPreset(preset)
            guard let draft else { return }
            try addDraft(id: draft.id, name: draft.name, endpoint: preset.endpoint.absoluteString, key: "", models: models)
            closeDetail()
            id = draft.id
        }
        guard let id else { return }
        // A server already in the list may host other models now: the proven one must resolve.
        setCatalog(id, models, preferred: nil)
        setShown(id, model: model, true)
        select(.init(providerID: id, modelID: model))
    }
}
