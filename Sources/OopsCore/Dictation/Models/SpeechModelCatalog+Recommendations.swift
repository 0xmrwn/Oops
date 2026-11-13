import Foundation

// A port of Hex's per-language model routing at v3.4.0 (MIT, github.com/anomalyco/hex): `choices_for_runtime`,
// `picker_models` and `recommended_selection` of `src/transcription/models.rs`. See THIRD_PARTY_NOTICES.md.

public enum SpeechModelRecommendation: Sendable, Equatable {
    case recommended
    case fastest
    case mostAccurate
    case vocabulary
}

public struct SpeechModelChoice: Sendable, Equatable {
    public let model: SpeechModel
    public let recommendation: SpeechModelRecommendation
}

public extension SpeechModelCatalog {
    /// The models Hex recommends for `language`, best first, each with its badge.
    static func choices(for language: String) -> [SpeechModelChoice] {
        let routes: [(SpeechModel, SpeechModelRecommendation)] = switch language {
        case SpeechLanguage.auto: [(whisperLargeV3Turbo, .recommended), (qwen3ASR06B, .fastest)]
        case "en": [(parakeetUnifiedEnglish, .recommended), (cohereTranscribe, .mostAccurate), (whisperLargeV3Turbo, .vocabulary)]
        case "zh": [(qwen3ASR06B, .recommended), (senseVoiceSmall, .fastest), (whisperLargeV3Turbo, .vocabulary)]
        case "yue", "ko": [(qwen3ASR06B, .recommended), (whisperLargeV3Turbo, .vocabulary)]
        // FLEURS Japanese test: Granite Speech 5.0 tied Whisper turbo at 2.4 times its speed, without vocabulary, so
        // it stays unbadged (Hex's run).
        case "ja": [(whisperLargeV3Turbo, .recommended), (senseVoiceSmall, .fastest)]
        case "el": [(cohereTranscribe, .recommended), (whisperLargeV3Turbo, .vocabulary)]
        case "fi", "sv", "da": [(whisperLargeV3Turbo, .recommended), (parakeetV3, .fastest)]
        case "mt": [(parakeetV3, .recommended)]
        case "ar": [(whisperLargeV3Turbo, .recommended), (cohereTranscribe, .mostAccurate)]
        case "tr", "ms", "fil", "fa", "mk": [(whisperLargeV3Turbo, .recommended)]
        // FLEURS Hebrew test: 18.45% WER against stock Whisper's 29.69%.
        case "he": [(ivritWhisperLargeV3Turbo, .recommended), (whisperLargeV3Turbo, .vocabulary)]
        // FLEURS Russian test: 5.37% WER against Parakeet v3's 6.52%, and Whisper turbo's 5.36% at a fifth of its speed.
        case "ru": [(gigaAMV3, .recommended), (whisperLargeV3Turbo, .vocabulary)]
        // FLEURS Norwegian test: 6.68% WER against Whisper turbo's 8.94%, at 0.89 times its speed.
        case "no": [(nbWhisperMedium, .recommended), (whisperLargeV3Turbo, .vocabulary)]
        case "vi": [(qwen3ASR06B, .recommended), (cohereTranscribe, .mostAccurate), (whisperLargeV3Turbo, .vocabulary)]
        case _ where parakeetV3Languages.contains(language): [(parakeetV3, .recommended), (whisperLargeV3Turbo, .vocabulary)]
        case _ where qwenLanguages.contains(language): [(qwen3ASR06B, .recommended), (whisperLargeV3Turbo, .vocabulary)]
        default: [(whisperLargeV3Turbo, .recommended)]
        }
        return routes.map { SpeechModelChoice(model: $0.0, recommendation: $0.1) }
    }

    /// Every model in the picker's order for `language`: its recommendations first, each with its badge, then the
    /// other models that support it, then those that would change the language.
    static func picker(for language: String) -> [(model: SpeechModel, recommendation: SpeechModelRecommendation?)] {
        let recommended = choices(for: language)
        let others = models.filter { model in recommended.allSatisfy { $0.model.id != model.id } }
        let supporting = others.filter { $0.supports(language: language) }
        let switching = others.filter { !$0.supports(language: language) }
        return recommended.map { ($0.model, $0.recommendation) } + (supporting + switching).map { ($0, nil) }
    }

    /// The first-run selection for `language`: its recommended model, with English for a language Hex does not list.
    static func recommendedSelection(for language: String) -> SpeechModelSelection {
        let language = SpeechLanguage.listed.contains { $0.code == language } ? language : "en"
        let choices = choices(for: language)
        let model = choices.first { $0.recommendation == .recommended }?.model ?? choices.first?.model
            ?? parakeetUnifiedEnglish
        return SpeechModelSelection(modelID: model.id, language: language)
    }
}
