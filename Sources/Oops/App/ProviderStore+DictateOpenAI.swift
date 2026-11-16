import Foundation
import OopsCore

extension ProviderStore {
    static let openAITranscriptionModel = RealtimeTranscription.model

    /// The OpenAI API provider with a key, which is what makes OpenAI's realtime transcription available. Nil in the
    /// screenshot preview, which holds no keys.
    var openAITranscriptionProvider: Provider? {
        providers.first { provider in
            guard case .api(let preset) = provider.kind, hasKey(provider.id) else { return false }
            return preset == "openai" || provider.baseURL.flatMap { URL(string: $0)?.host } == "api.openai.com"
        }
    }

    var openAIDictateReference: VoiceModelReference? {
        openAITranscriptionProvider.map { .provider(.init(providerID: $0.id, modelID: Self.openAITranscriptionModel)) }
    }

    /// Whether OpenAI's model is the one dictation uses now: selected, with its key still there.
    func dictatesWithOpenAI(_ local: LocalModels) -> Bool {
        guard let reference = openAIDictateReference else { return false }
        return dictateModel(local) == reference
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
