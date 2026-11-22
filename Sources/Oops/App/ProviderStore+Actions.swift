import Foundation
import OopsCore

/// The model each action runs on: its own while it's still switched on, else Fix's (Same as Fix) at its lightest effort.
extension ProviderStore {
    func actionModel(_ run: ActionModelRun) -> (choice: ModelSelection.Choice, settings: ModelSelection.Settings)? {
        // Switched on at its provider, and not known to take no text: decided from what is saved, so a catalog that
        // hasn't loaded yet never sends the action to another provider.
        if let chosen = run.choice, provider(chosen.providerID)?.shownModels.contains(chosen.modelID) == true,
           capabilities(chosen).capabilities.map(ModelFeature.fix.accepts) ?? true {
            // A catalog not loaded yet keeps the saved effort; a model listing no efforts gets none sent.
            guard let model = catalogs[chosen.providerID]?.first(where: { $0.id == chosen.modelID }) else {
                return (chosen, .init(effort: run.effort))
            }
            let effort = run.effort.flatMap { ModelSelection.nearestEffort($0, in: model) } ?? ModelSelection.lightest(model).effort
            return (chosen, .init(effort: effort))
        }
        guard let fix = selection.choice, provider(fix.providerID) != nil else { return nil }
        return (fix, currentModel.map(ModelSelection.lightest) ?? .init())
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
