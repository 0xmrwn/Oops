import Foundation

// A port of the model catalog of Hex at v3.4.0 (MIT, github.com/anomalyco/hex): `MODELS`, `definition` and
// `SPEECH_DETECTOR_ARTIFACT` of `src/transcription/models.rs`, and the shared language lists of
// `src/transcription/artifacts.rs`. See THIRD_PARTY_NOTICES.md.

/// The speech models Oops can download, in Hex's order. Each family's entries live in its own
/// `SpeechModelCatalog+<Family>.swift`.
public enum SpeechModelCatalog {
    public static let models: [SpeechModel] = [
        parakeetUnifiedEnglish, parakeetV2, parakeetV3, orukeet, whisperLargeV3Turbo, qwen3ASR06B,
        qwenCleoASR17B, ivritWhisperLargeV3Turbo, senseVoiceSmall, cohereTranscribe, underdogBark3Pro,
        underdogBark3Clean, parakeetUltra, nemotron35ASR, gigaAMV3, nbWhisperMedium, graniteSpeech5
    ]

    public static func model(id: String) -> SpeechModel? {
        models.first { $0.id == id }
    }

    /// Silero VAD v6.2. Hex downloads it with every model so audio without speech is skipped: models
    /// hallucinate closing phrases such as "thank you" on silence and room noise.
    public static let speechDetector = SpeechModelArtifact(
        fileName: "silero-vad-v6.2-F32.gguf",
        repository: "handy-computer/silero-vad-v6.2-gguf",
        revision: "a9b2d61c20ae4ddf3644edb34969e8185a485448",
        byteCount: 1_241_056,
        sha256: "0d871a800c420fdd5d1b17a3aea4296d1c39608f0ff4a9295eb76457eb1c88e6")

    /// Hex's `max_audio_chunk_samples`: the longest clip, in 16 kHz samples, to hand a model at once. Cohere's
    /// encoder capacity is not its recommended window; its reference processor chunks at 35 seconds.
    public static func maxAudioChunkSamples(architecture: SpeechModelArchitecture, maxAudioMilliseconds: Int) -> Int? {
        let limit = if architecture == .cohereASR {
            maxAudioMilliseconds > 0 ? min(maxAudioMilliseconds, 35_000) : 35_000
        } else {
            maxAudioMilliseconds
        }
        return limit > 0 ? limit * 16 : nil
    }

    // MARK: Shared language lists

    static let parakeetV3Languages: [String] = [
        "bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "hu", "it", "lv", "lt", "mt",
        "pl", "pt", "ro", "ru", "sk", "sl", "es", "sv", "uk"
    ]
    static let qwenLanguages: [String] = [
        "zh", "en", "yue", "ar", "de", "fr", "es", "pt", "id", "it", "ko", "ru", "th", "vi", "ja",
        "tr", "hi", "ms", "nl", "sv", "da", "fi", "pl", "cs", "fil", "fa", "el", "ro", "hu", "mk"
    ]
    static let cohereLanguages: [String] = [
        "en", "fr", "de", "es", "it", "pt", "nl", "pl", "el", "ar", "ja", "zh", "vi", "ko"
    ]
    static let graniteSpeech5Languages: [String] = ["en", "fr", "de", "es", "pt", "it", "ja"]
    static let nemotron35Languages: [String] = [
        "en", "es", "fr", "de", "it", "pt", "nl", "tr", "ru", "uk", "pl", "cs", "sk", "bg", "hr", "ro",
        "hu", "sv", "da", "fi", "et", "ar", "hi", "ja", "ko", "zh", "vi"
    ]
    /// The locales Nemotron's language prompt takes, for the languages Hex names.
    static let nemotron35Locales: [String: String] = [
        "en": "en-US", "es": "es-ES", "fr": "fr-FR", "de": "de-DE", "it": "it-IT", "pt": "pt-BR",
        "nl": "nl-NL", "tr": "tr-TR", "ru": "ru-RU", "uk": "uk-UA", "pl": "pl-PL", "cs": "cs-CZ",
        "sk": "sk-SK", "bg": "bg-BG", "hr": "hr-HR", "ro": "ro-RO", "hu": "hu-HU", "sv": "sv-SE",
        "da": "da-DK", "fi": "fi-FI", "et": "et-EE", "ar": "ar-AR", "hi": "hi-IN", "ja": "ja-JP",
        "ko": "ko-KR", "zh": "zh-CN", "vi": "vi-VN"
    ]
}

extension SpeechModelLicense {
    static let ccBy4 = SpeechModelLicense(
        name: "CC-BY-4.0", url: URL(string: "https://creativecommons.org/licenses/by/4.0/legalcode.en#s3a"))
    static let ccBySa4 = SpeechModelLicense(
        name: "CC-BY-SA-4.0", url: URL(string: "https://creativecommons.org/licenses/by-sa/4.0/legalcode.en#s3a"))
    static let apache2 = SpeechModelLicense(name: "Apache-2.0")
    static let mit = SpeechModelLicense(name: "MIT")
    static let openMDW = SpeechModelLicense(name: "OpenMDW-1.1")
}
