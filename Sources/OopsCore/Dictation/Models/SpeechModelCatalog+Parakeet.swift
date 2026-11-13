import Foundation

// Parakeet-family entries of Hex's catalog at v3.4.0 (MIT, github.com/anomalyco/hex), from
// `src/transcription/models.rs` and `src/transcription/artifacts.rs`. See THIRD_PARTY_NOTICES.md.

extension SpeechModelCatalog {
    static let parakeetUnifiedEnglish = SpeechModel(
        id: "parakeet_unified_en", name: "Parakeet Unified English",
        artifact: SpeechModelArtifact(
            fileName: "parakeet-unified-en-0.6b-Q8_0.gguf",
            repository: "handy-computer/parakeet-unified-en-0.6b-gguf",
            revision: "7e948f21b7bdbac698d3318db9d350f1096f3b6c",
            byteCount: 731_357_568,
            sha256: "4b50b6dd862bf6e346929aaf4f5eaacec003bfa3f56462d6c874b41ef2f38795"),
        architecture: .parakeet, variant: "unified-en-0.6b", languages: .one("en"),
        // Hex buffers it with its largest context, its most accurate and least compute-intensive setting.
        streams: true,
        streamingChunk: SpeechModelStreamingChunk(leftMilliseconds: 5600, chunkMilliseconds: 1040, rightMilliseconds: 1040),
        acceptsLanguageHint: true, supportsLanguageDetection: false,
        wordErrorRate: 1.60, realtime: "~163x")

    static let parakeetV2 = SpeechModel(
        id: "parakeet_v2", name: "Parakeet v2",
        artifact: SpeechModelArtifact(
            fileName: "parakeet-tdt-0.6b-v2-Q8_0.gguf",
            repository: "handy-computer/parakeet-tdt-0.6b-v2-gguf",
            revision: "07cee0616125a08ef619729bb47f40ef747e4bc4",
            byteCount: 729_574_912,
            sha256: "f0d0e99cebb6d3b83f1f7069b82b5d3c2e39a54545b0da039cb4bafd9c4e5caa"),
        architecture: .parakeet, variant: "tdt-0.6b-v2", languages: .one("en"),
        acceptsLanguageHint: true, supportsLanguageDetection: false,
        wordErrorRate: 1.69, realtime: "~55x")

    // The pinned v3 artifact detects the language from audio and has no prompt input, so it is offered under Auto.
    static let parakeetV3 = SpeechModel(
        id: "parakeet_v3", name: "Parakeet v3",
        artifact: SpeechModelArtifact(
            fileName: "parakeet-tdt-0.6b-v3-Q8_0.gguf",
            repository: "handy-computer/parakeet-tdt-0.6b-v3-gguf",
            revision: "85ac09ea12fc4b1112fa76810059364bc6adc9de",
            byteCount: 739_508_576,
            sha256: "5859f77944efcd8eafa23a6350731960b2b55b2203df51f319665c807d802cc7"),
        architecture: .parakeet, variant: "tdt-0.6b-v3", languages: .many(parakeetV3Languages),
        acceptsLanguageHint: false, supportsLanguageDetection: true,
        wordErrorRate: 1.94, realtime: "~33x")

    // Oruk AI's Parakeet TDT 0.6B v3 fine-tune, converted by handy-computer. Like v3 it detects the language.
    static let orukeet = SpeechModel(
        id: "orukeet", name: "Orukeet",
        artifact: SpeechModelArtifact(
            fileName: "orukeet-Q8_0.gguf",
            repository: "handy-computer/orukeet-gguf",
            revision: "c5511a3850fce1cbbfa5d94ef815966e1d99275f",
            byteCount: 739_508_704,
            sha256: "68cd64b2a6c3c747f0a9f109884ed75b277c266c0fb8e5888c5a9f4d824fb9f7"),
        architecture: .parakeet, variant: "tdt-0.6b-orukeet", languages: .many(parakeetV3Languages),
        acceptsLanguageHint: false, supportsLanguageDetection: true, license: .ccBySa4,
        // LibriSpeech test-clean, transcribe.cpp's published conversion benchmark; the speed is v3's figure.
        wordErrorRate: 1.86, realtime: "~33x")

    // Conway Research's Parakeet TDT v3 fine-tunes, converted with transcribe.cpp's Parakeet converter. As with v3,
    // the artifact has no language input.
    static let underdogBark3Pro = SpeechModel(
        id: "underdog_bark_3_pro", name: "Underdog Bark 3.0 Pro",
        artifact: SpeechModelArtifact(
            fileName: "underdog-bark-3.0-pro-Q8_0.gguf",
            repository: "joshthomasdev/underdog-bark-3.0-pro-gguf",
            revision: "5c10586263806666c0a8b4905a3346a7c679803e",
            byteCount: 739_508_480,
            sha256: "472d151cc1546bd30629c4c25df3a8e555e8990845843ddafe76800c640e9865"),
        architecture: .parakeet, variant: "tdt-0.6b-bark-3.0-pro", languages: .one("en"),
        acceptsLanguageHint: false, supportsLanguageDetection: false, license: .ccBy4,
        wordErrorRate: 1.38, realtime: "~33x")

    static let underdogBark3Clean = SpeechModel(
        id: "underdog_bark_3_clean", name: "Underdog Bark 3.0 Clean",
        artifact: SpeechModelArtifact(
            fileName: "underdog-bark-3.0-clean-Q8_0.gguf",
            repository: "joshthomasdev/underdog-bark-3.0-clean-gguf",
            revision: "868701fd53d62c59d759ed1d79e095118f3fa7b9",
            byteCount: 739_508_480,
            sha256: "42ec2f70a3d14842e322391baf5186b2829f271cc7e396aed25580135ae46fae"),
        architecture: .parakeet, variant: "tdt-0.6b-bark-3.0-clean", languages: .one("en"),
        acceptsLanguageHint: false, supportsLanguageDetection: false, license: .ccBy4,
        wordErrorRate: 1.71, realtime: "~33x")

    // Moondream's post-trained Parakeet TDT 0.6B v3, quantized by handy-computer. Hex hides it behind a Labs
    // switch; here it is an ordinary entry.
    static let parakeetUltra = SpeechModel(
        id: "parakeet_ultra", name: "Parakeet Ultra",
        artifact: SpeechModelArtifact(
            fileName: "parakeet-ultra-Q8_0.gguf",
            repository: "handy-computer/parakeet-ultra-gguf",
            revision: "a1539be1b849ea7463b88343e5277b373d0c4ea9",
            byteCount: 740_363_168,
            sha256: "007a59761e9258779f189df396b50d12b83bb5b79e66df4b955c230d2f2a0a59"),
        architecture: .parakeet, variant: "tdt-0.6b-ultra", languages: .many(parakeetV3Languages),
        acceptsLanguageHint: false, supportsLanguageDetection: true, license: .ccBy4,
        wordErrorRate: 1.80, realtime: "~33x")

    // NVIDIA's cache-aware FastConformer with a language-prompted RNN-T. Its prompt takes locales, and Auto leaves
    // the language to the model. Parakeet v3 made fewer errors on the same runs; it is here to stream with the
    // language set.
    static let nemotron35ASR = SpeechModel(
        id: "nemotron_3_5_asr", name: "Nemotron 3.5 ASR",
        artifact: SpeechModelArtifact(
            fileName: "nemotron-3.5-asr-streaming-0.6b-Q8_0.gguf",
            repository: "handy-computer/nemotron-3.5-asr-streaming-0.6b-gguf",
            revision: "53ce288f69326b415aeef030cfcb02a08a8096dd",
            byteCount: 751_094_240,
            sha256: "b94545b313b3223fda7b2857a52681da813935c2127643d1e9ff0c23d988089c"),
        architecture: .parakeet, variant: "nemotron-3.5-asr-streaming-0.6b",
        languages: .many(nemotron35Languages), streams: true,
        acceptsLanguageHint: true, supportsLanguageDetection: true,
        runtimeLanguages: nemotron35Locales, license: .openMDW,
        wordErrorRate: 3.05, realtime: "~25x")
}
