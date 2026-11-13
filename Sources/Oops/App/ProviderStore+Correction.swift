import Foundation
import OopsCore

extension ProviderStore {
    // MARK: Correcting

    /// The chosen backend, shared by preparation and submission until the attempt ends.
    func backend() throws -> any CorrectionBackend {
        #if DEBUG
        if let control = DebugFlags.stubProvider { return StubBackend(control: control) }
        #endif
        guard let choice = selection.choice, let provider = currentProvider else {
            throw CorrectionError.failure(.setup, "Choose a model in Settings.")
        }
        let settings = selection.settings(for: choice)
        let identity = correctionIdentity
        if let cached, cached.identity == identity { return cached.backend }
        let backend = try backend(provider, choice, settings)
        cached = (identity, backend)
        return backend
    }

    /// A backend for `choice` on `provider` at `settings`, whichever feature asks.
    func backend(_ provider: Provider, _ choice: ModelSelection.Choice, _ settings: ModelSelection.Settings) throws -> any CorrectionBackend {
        if let makeBackend { return try makeBackend(provider, choice, settings) }
        switch provider.kind {
        case .chatGPT:
            let model = catalogs[provider.id]?.first { $0.id == choice.modelID }
            let tier = settings.fast ? model?.fast?.id : nil
            return ChatGPTBackend(auth: chatGPT, model: choice.modelID, effort: settings.effort ?? ModelSelection.defaultEffort, serviceTier: tier)
        case .claudeCode:
            guard let runtime = claudeRuntime ?? ClaudeCodeRuntime.locate(directory: Self.claudeDirectory, askShell: false) else {
                throw CorrectionError.failure(.setup, "Install Claude Code to correct with Claude.")
            }
            claudeRuntime = runtime
            return ClaudeCodeBackend(runtime: runtime, model: choice.modelID, effort: settings.effort)
        case .api:
            return try provider.apiBackend(model: choice.modelID, apiKey: readKey(provider.id), effort: settings.effort)
        }
    }

    func endCorrection(_ request: ProviderCorrection, discardBackend: Bool) {
        guard activeCorrection === request else { return }
        activeCorrection = nil
        if discardBackend { cached = nil }
    }

    /// The chosen model as the debug log records it.
    var debugModel: DebugAttempt.Model? {
        #if DEBUG
        if DebugFlags.stubProvider != nil { return .init(provider: "stub", providerName: "Stub", id: "stub", effort: nil, fast: false) }
        #endif
        guard let choice = selection.choice, let provider = currentProvider else { return nil }
        let settings = selection.settings(for: choice)
        let kind = switch provider.kind { case .chatGPT: "chatgpt"; case .claudeCode: "claude-code"; case .api: "api" }
        return .init(provider: kind, providerName: provider.name, id: choice.modelID, effort: settings.effort, fast: settings.fast)
    }
}
