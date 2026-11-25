import Foundation
import OopsCore

extension ProviderStore {
    static let openAITranscriptionModel = RealtimeTranscription.model

    /// The OpenAI API providers, with a key or not.
    private var openAIProviders: [Provider] {
        providers.filter { provider in
            guard case .api(let preset) = provider.kind else { return false }
            return preset == "openai" || provider.baseURL.flatMap { URL(string: $0)?.host } == "api.openai.com"
        }
    }

    /// The OpenAI API provider with a key, which is what makes OpenAI's realtime transcription available. Nil in the
    /// screenshot preview, which holds no keys.
    var openAITranscriptionProvider: Provider? { openAIProviders.first { hasKey($0.id) } }

    /// Where the key that turns OpenAI's transcription on is entered: the OpenAI provider's page when there is
    /// one, else a new provider filled in for OpenAI.
    func setUpOpenAITranscription() {
        if let existing = openAIProviders.first {
            openProvider = existing.id
        } else {
            startDraft()
            chooseDraftPreset(ProviderPreset(id: "openai"))
        }
        wantsProvidersPage = true
    }

    var openAIDictateReference: VoiceModelReference? {
        openAITranscriptionProvider.map { .provider(.init(providerID: $0.id, modelID: Self.openAITranscriptionModel)) }
    }

    /// Whether OpenAI's model is the one dictation uses now: selected, with its key still there.
    func dictatesWithOpenAI(_ local: LocalModels) -> Bool {
        guard let reference = openAIDictateReference else { return false }
        return dictateModel(local) == reference
    }

    /// Whether `provider` is the OpenAI key dictation transcribes with and nothing else uses: none of its models is
    /// switched on. The screenshot preview, which holds no keys, has its own OpenAI for this.
    func speechOnly(_ provider: Provider, local: LocalModels) -> Bool {
        if preview { return provider.id == "preview-openai" }
        return provider.shownModels.isEmpty && provider.id == openAITranscriptionProvider?.id && dictatesWithOpenAI(local)
    }

    /// The chosen language as an ISO 639-1 code, which is all the service takes; nil under Automatic.
    var openAILanguage: String? { dictateSelection.language.flatMap { $0.count == 2 ? $0 : nil } }

    /// The engine for a dictation when OpenAI's model is the one in use; nil for a local model, or with no key. The
    /// key is read here, at the press, so a changed key applies to the next dictation.
    func dictationHostedEngine(_ local: LocalModels) -> (any SpeechEngine)? {
        guard dictatesWithOpenAI(local), let provider = openAITranscriptionProvider else { return nil }
        let key = readKey(provider.id)
        return key.isEmpty ? nil : OpenAIRealtimeEngine(apiKey: key)
    }
}
