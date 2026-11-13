import Foundation

// The Qwen3-ASR, SenseVoice, Cohere, GigaAM and Granite entries of Hex's catalog at v3.4.0 (MIT,
// github.com/anomalyco/hex), from `src/transcription/models.rs` and `src/transcription/artifacts.rs`. See
// THIRD_PARTY_NOTICES.md.

extension SpeechModelCatalog {
    static let qwen3ASR06B = SpeechModel(
        id: "qwen3_asr06_b", name: "Qwen3-ASR 0.6B",
        artifact: SpeechModelArtifact(
            fileName: "Qwen3-ASR-0.6B-Q8_0.gguf",
            repository: "handy-computer/Qwen3-ASR-0.6B-gguf",
            revision: "e4e16599b900eb0cb36e524514756bb92eb092b7",
            byteCount: 850_423_456,
            sha256: "f081b2d5e23bd669d92cc331d722a8a0681943b8e6f34b48996fd5c319b5acd8"),
        architecture: .qwen3ASR, variant: "qwen3-asr-0.6b", languages: .many(qwenLanguages),
        acceptsLanguageHint: true, supportsLanguageDetection: true, license: .apache2,
        wordErrorRate: 7.64, realtime: "~16x")

    // Mohammed Aly's Qwen3-ASR 1.7B fine-tune for Egyptian Arabic and Arabic/English code-switching. The error rate
    // is the author's own 3,699-utterance evaluation, not a public test set.
    static let qwenCleoASR17B = SpeechModel(
        id: "qwencleo_asr_1_7b", name: "QwenCleo-ASR 1.7B",
        artifact: SpeechModelArtifact(
            fileName: "QwenCleo-ASR-1.7B-Q8_0.gguf",
            repository: "reomar15/QwenCleo-ASR-transcribe-cpp-GGUF",
            revision: "08c66976a0496e1e3f1a88965eea123631e634fa",
            byteCount: 2_185_030_816,
            sha256: "43bae9d5d7a26684b4a0faf1abc6e872b5825cc9147dbb7200da9ff4c5d12f87"),
        architecture: .qwen3ASR, variant: "qwen3-asr-1.7b", languages: .one("ar"),
        acceptsLanguageHint: true, supportsLanguageDetection: false, license: .apache2,
        wordErrorRate: 19.85, realtime: "~9x")

    static let senseVoiceSmall = SpeechModel(
        id: "sense_voice_small", name: "SenseVoice Small",
        artifact: SpeechModelArtifact(
            fileName: "SenseVoiceSmall-Q8_0.gguf",
            repository: "handy-computer/SenseVoiceSmall-gguf",
            revision: "4a08b8e900b38a977e32eb08d5d0697d6e72ba04",
            byteCount: 252_684_608,
            sha256: "6c759ee4c9748c9b3f7a5a60ca74f0f7e685fb9d45d1378fce7cfd62f59adf29"),
        architecture: .senseVoice, variant: "sensevoice-small", languages: .many(["zh", "yue", "en", "ja", "ko"]),
        acceptsLanguageHint: true, supportsLanguageDetection: true, license: .funASRModel,
        wordErrorRate: 10.11, realtime: "~72x")

    static let cohereTranscribe = SpeechModel(
        id: "cohere_transcribe", name: "Cohere Transcribe",
        artifact: SpeechModelArtifact(
            fileName: "cohere-transcribe-03-2026-Q8_0.gguf",
            repository: "handy-computer/cohere-transcribe-03-2026-gguf",
            revision: "dfa4adebb64f3076b7b6b90b721275cc069cb421",
            byteCount: 2_410_655_232,
            sha256: "931916663432fd895423a4291a8400221802b288967ca2d435fc5e3141c9e71e"),
        architecture: .cohereASR, variant: "cohere-transcribe-03-2026", languages: .many(cohereLanguages),
        acceptsLanguageHint: true, supportsLanguageDetection: false, license: .apache2,
        wordErrorRate: 1.27, realtime: "73x")

    // ai-sage's GigaAM v3 e2e RNN-T, Russian only, cased and punctuated. It has no language input. The error rate
    // is FLEURS Russian test, Hex's own run.
    static let gigaAMV3 = SpeechModel(
        id: "gigaam_v3", name: "GigaAM v3",
        artifact: SpeechModelArtifact(
            fileName: "gigaam-v3-e2e-rnnt-Q8_0.gguf",
            repository: "handy-computer/gigaam-v3-e2e-rnnt-gguf",
            revision: "3efd5b39882ceadca5570a8fb9fa1a2c801d6d6d",
            byteCount: 273_724_832,
            sha256: "78d63b47723b7f8d78c6113a6ef983b5a86e2a86f6c273e1f5cb6967b1c4467a"),
        architecture: .gigaAM, variant: "gigaam-v3-e2e-rnnt", languages: .one("ru"),
        acceptsLanguageHint: false, supportsLanguageDetection: false, license: .mit,
        wordErrorRate: 5.37, realtime: "~40x")

    // IBM's multilingual Granite Speech 5.0 TurboCTC. A CTC head with no language input: it transcribes whichever of
    // its seven languages it hears, so Hex offers it under Auto although its file leaves lang_detect off.
    static let graniteSpeech5 = SpeechModel(
        id: "granite_speech_5", name: "Granite Speech 5.0",
        artifact: SpeechModelArtifact(
            fileName: "granite-speech-5.0-470m-turboctc-multilingual-Q8_0.gguf",
            repository: "17slever17/granite-speech-5.0-470m-turboctc-multilingual-GGUF",
            revision: "62f64d9d5ad35989b06caf199cafe7155944a22b",
            byteCount: 505_663_136,
            sha256: "f3efdc05b85b3a764bb5bb7022e69f61cafcecc11605c881c6396a6ed07ec91b"),
        architecture: .graniteSpeech5CTC, variant: "granite-speech-5.0-470m-turboctc",
        languages: .many(graniteSpeech5Languages),
        acceptsLanguageHint: false, supportsLanguageDetection: true, license: .apache2,
        wordErrorRate: 4.77, realtime: "~25x")
}
