import Foundation

/// An engine the vocabulary may have to reach: a local model, by the architecture the catalog already names, or
/// OpenAI's transcription.
public enum VocabularyEngine: Sendable, Equatable {
    case local(SpeechModelArchitecture)
    case openAI
}

/// What one engine receives from the user's vocabulary, as plain values. Nothing here binds an engine call.
public enum VocabularyDelivery: Sendable, Equatable {
    /// Parakeet: the engine's vocabulary extension.
    case parakeetBias(VocabularyBias)
    /// Whisper and Qwen3-ASR: their context prompt.
    case prompt(String)
    /// OpenAI: the `keywords` list.
    case openAIKeywords([String])
    /// An engine with no mechanism of its own: fuzzy replacement of these terms after transcription.
    case fuzzyReplacement([String])
}

public enum VocabularyRouting {
    /// Which mechanism receives the vocabulary for `engine`, and with what; nil, so nothing at all, for an empty
    /// vocabulary on every engine (a Parakeet boost of `.off` sends nothing either, as in Hex).
    public static func delivery(
        of entries: [VocabularyEntry], to engine: VocabularyEngine, boost: VocabularyBoost = .normal
    ) -> VocabularyDelivery? {
        if entries.isEmpty { return nil }
        switch engine {
        case .openAI:
            return .openAIKeywords(entries.map(\.term))
        case let .local(architecture):
            switch architecture.vocabularyUse {
            case .bias: return VocabularyBias.make(entries, boost: boost).map(VocabularyDelivery.parakeetBias)
            case .prompt:
                return VocabularyPrompt.maxCharacters(for: architecture)
                    .flatMap { VocabularyPrompt.make(entries, maxCharacters: $0) }.map(VocabularyDelivery.prompt)
            case .none: return .fuzzyReplacement(entries.map(\.term))
            }
        }
    }
}
