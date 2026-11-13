import Foundation

// Whisper-family entries of Hex's catalog at v3.4.0 (MIT, github.com/anomalyco/hex), from
// `src/transcription/models.rs` and `src/transcription/artifacts.rs`. See THIRD_PARTY_NOTICES.md.

extension SpeechModelCatalog {
    // Hex marks it `"*"`: it takes any language Hex knows, and Hex hands the engine `tl` for Filipino.
    static let whisperLargeV3Turbo = SpeechModel(
        id: "whisper_large_v3_turbo", name: "Whisper large-v3-turbo",
        artifact: SpeechModelArtifact(
            fileName: "whisper-large-v3-turbo-Q8_0.gguf",
            repository: "handy-computer/whisper-large-v3-turbo-gguf",
            revision: "d222c9f621c1128299248f2ded4d8a1820519780",
            byteCount: 886_381_824,
            sha256: "d5e65f2b0828802ae2c231673d31982cebe3a778c95d9494a9f3efee6bd17448"),
        architecture: .whisper, variant: "whisper-large-v3-turbo", languages: .anyKnown,
        acceptsLanguageHint: true, supportsLanguageDetection: true, runtimeLanguages: ["fil": "tl"],
        license: .mit,
        wordErrorRate: 2.01, realtime: "~19x")

    // ivrit.ai's Hebrew fine-tune: it lost language detection and translation, so it always runs with the Hebrew hint.
    static let ivritWhisperLargeV3Turbo = SpeechModel(
        id: "ivrit_whisper_large_v3_turbo", name: "ivrit.ai Whisper large-v3-turbo",
        artifact: SpeechModelArtifact(
            fileName: "ivrit-whisper-large-v3-turbo-Q8_0.gguf",
            repository: "adolan/ivrit-whisper-large-v3-turbo-gguf",
            revision: "a12befaff80add995ac6a8fe10cbb7f38438c7b5",
            byteCount: 886_381_536,
            sha256: "23756afa3d3c52cd3cb55e259c8373373eba6d19c3858a67531ba2772b7f272f"),
        architecture: .whisper, variant: "ivrit-whisper-large-v3-turbo", languages: .one("he"),
        acceptsLanguageHint: true, supportsLanguageDetection: false, license: .apache2,
        wordErrorRate: 18.45, realtime: "~19x")

    // The National Library of Norway's Whisper medium fine-tune: NbAiLab's own whisper.cpp Q5_0 file, which
    // transcribe.cpp loads as Whisper. Measured only for Bokmal with the `no` hint, which it always gets.
    static let nbWhisperMedium = SpeechModel(
        id: "nb_whisper_medium", name: "NB-Whisper Medium",
        artifact: SpeechModelArtifact(
            fileName: "ggml-model-q5_0.bin",
            repository: "NbAiLab/nb-whisper-medium",
            revision: "0ed074d5985bd56ca4140159a9dbffbc3fb5117e",
            byteCount: 539_212_484,
            sha256: "18733de634af639a43b0f8c5f5a2ea0920de4c5b32a5570ec130981581c0e5e7"),
        architecture: .whisper, variant: "whisper-medium", languages: .one("no"),
        acceptsLanguageHint: true, supportsLanguageDetection: false, license: .apache2,
        wordErrorRate: 6.68, realtime: "~17x")
}
