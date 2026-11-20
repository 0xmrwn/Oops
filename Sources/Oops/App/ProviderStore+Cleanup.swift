import Foundation
import OopsCore

/// Dictation's Clean up: its own model, from the switched-on models that take text, and a backend for it that
/// shares nothing with Fix's.
extension ProviderStore {
    /// The models Clean up can use: every switched-on model, less the ones known to take no text (a speech model).
    var cleanupOptions: [ModelSelection.Choice] {
        pickerGroups.flatMap { group in
            group.models.map { ModelSelection.Choice(providerID: group.provider.id, modelID: $0.id) }
                .filter { capabilities($0).capabilities.map(ModelFeature.fix.accepts) ?? true }
        }
    }

    /// The model Clean up uses: the one chosen while it's still switched on, else Fix's, else the first one there is.
    var cleanupChoice: ModelSelection.Choice? {
        let options = cleanupOptions
        if let chosen = features.cleanup, options.contains(chosen) { return chosen }
        if let fix = selection.choice, options.contains(fix) { return fix }
        return options.first
    }

    /// A model's name as the menus show it.
    func modelName(_ choice: ModelSelection.Choice) -> String {
        catalogs[choice.providerID]?.first { $0.id == choice.modelID }?.name ?? ModelSelection.modelName(choice.modelID)
    }

    /// Whether Clean up has a model to use, known without building its backend, which reads the Keychain.
    var hasCleanupModel: Bool {
        #if DEBUG
        if DebugFlags.stubProvider != nil { return true }
        #endif
        return cleanupChoice.flatMap { provider($0.providerID) } != nil
    }

    /// A fresh backend for Clean up's model, at the lightest effort the model accepts: a cleanup is a rewrite, not a problem to think through.
    func cleanupBackend() throws -> any CorrectionBackend {
        #if DEBUG
        if let control = DebugFlags.stubProvider { return StubBackend(control: control) }
        #endif
        guard let choice = cleanupChoice, let provider = provider(choice.providerID) else {
            throw CorrectionError.failure(.setup, "Choose a model for Clean up.")
        }
        let model = catalogs[choice.providerID]?.first { $0.id == choice.modelID }
        return try backend(provider, choice, model.map(ModelSelection.lightest) ?? .init())
    }
}
