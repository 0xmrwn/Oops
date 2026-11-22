import Foundation
import OopsCore

/// The model each action runs on: its own while it's still switched on, else Fix's (Same as Fix) at its lightest effort.
extension ProviderStore {
    /// `followsFix` says the run fell back to Fix's model, so a summary names what runs rather than guessing it.
    func actionModel(_ run: ActionModelRun) -> (choice: ModelSelection.Choice, settings: ModelSelection.Settings, followsFix: Bool)? {
        // Switched on at its provider, and not known to take no text: decided from what is saved, so a catalog that
        // hasn't loaded yet never sends the action to another provider.
        if let chosen = run.choice, provider(chosen.providerID)?.shownModels.contains(chosen.modelID) == true,
           capabilities(chosen).capabilities.map(ModelFeature.fix.accepts) ?? true {
            // A catalog not loaded yet keeps the saved effort; a model listing no efforts gets none sent.
            guard let model = catalogs[chosen.providerID]?.first(where: { $0.id == chosen.modelID }) else {
                return (chosen, .init(effort: run.effort), false)
            }
            let effort = run.effort.flatMap { ModelSelection.nearestEffort($0, in: model) } ?? ModelSelection.lightest(model).effort
            return (chosen, .init(effort: effort), false)
        }
        guard let fix = selection.choice, provider(fix.providerID) != nil else { return nil }
        return (fix, currentModel.map(ModelSelection.lightest) ?? .init(), true)
    }

    /// A fresh backend for the run; an action has no model at all only when no provider is set up.
    func actionBackend(_ run: ActionModelRun) throws -> any CorrectionBackend {
        #if DEBUG
        if let control = DebugFlags.stubProvider { return StubBackend(control: control) }
        #endif
        guard let target = actionModel(run), let provider = provider(target.choice.providerID) else { throw ActionFailure.noModel }
        do { return try backend(provider, target.choice, target.settings) } catch { throw ActionFailure.model(error) }
    }
}

/// What the editor's Runs with row says, as the run resolves it.
extension ProviderStore {
    /// Claude Code's own models, as its live `initialize` lists them, for an agent.
    var agentModels: [CatalogModel] { catalogs["claude-code"] ?? [] }

    /// The agent's model: the chosen one while Claude Code lists it, else its preferred, else its first.
    func agentModel(_ run: ActionAgentRun) -> CatalogModel? {
        let models = agentModels
        return models.first { $0.id == run.model } ?? models.first { ModelSelection.preferredClaude.contains($0.id) } ?? models.first
    }

    func runsWithSummary(_ runsWith: ActionRunsWith) -> String {
        switch runsWith.kind {
        case .model:
            let target = actionModel(runsWith.model)
            let text = ActionRunSummary.model(sameAsFix: target?.followsFix ?? true, name: target.map { modelName($0.choice) },
                                              effort: target?.settings.effort)
            return text.isEmpty ? "Choose a model" : text
        case .agent:
            let model = agentModel(runsWith.agent)
            return ActionRunSummary.agent(model: model?.name, effort: model.flatMap { ModelSelection.nearestEffort(runsWith.agent.effort, in: $0) },
                                          runsWith.agent)
        }
    }
}
