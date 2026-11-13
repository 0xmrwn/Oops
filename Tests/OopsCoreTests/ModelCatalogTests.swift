import XCTest
@testable import OopsCore

/// The catalog's own shape, and Hex's catalog tests (`src/transcription/models.rs` at v3.4.0) that need no files or
/// settings, each under its upstream name in the Swift style. Hex's tests of download verification, receipts,
/// removal, imports, benchmarks and the Apple Speech entry belong to code Oops does not port.
final class ModelCatalogTests: XCTestCase {
    func model(_ id: String, file: StaticString = #filePath, line: UInt = #line) throws -> SpeechModel {
        try XCTUnwrap(SpeechModelCatalog.model(id: id), "no catalog model \(id)", file: file, line: line)
    }

    // MARK: Shape

    func testEveryEntryPinsItsFileAndHasAName() {
        for model in SpeechModelCatalog.models {
            let artifact = model.artifact
            XCTAssertFalse(model.name.isEmpty, model.id)
            XCTAssertFalse(artifact.fileName.isEmpty, model.id)
            XCTAssertFalse(artifact.repository.isEmpty, model.id)
            XCTAssertFalse(artifact.revision.isEmpty, model.id)
            XCTAssertGreaterThan(artifact.byteCount, 0, model.id)
            XCTAssertFalse(model.variant.isEmpty, model.id)
            XCTAssertFalse(model.license.name.isEmpty, model.id)
            XCTAssertFalse(model.realtime.isEmpty, model.id)
            XCTAssertFalse(model.languages.codes.isEmpty, model.id)
            let hex = artifact.sha256
            XCTAssertEqual(hex.count, 64, model.id)
            XCTAssertTrue(hex.allSatisfy { $0.isHexDigit && !$0.isUppercase }, model.id)
        }
    }

    func testRevisionsAreFullCommitHashes() {
        for artifact in SpeechModelCatalog.models.map(\.artifact) + [SpeechModelCatalog.speechDetector] {
            XCTAssertEqual(artifact.revision.count, 40, artifact.fileName)
            XCTAssertTrue(artifact.revision.allSatisfy(\.isHexDigit), artifact.fileName)
        }
    }

    func testIdsAndFilesAreUnique() {
        let models = SpeechModelCatalog.models
        XCTAssertEqual(Set(models.map(\.id)).count, models.count)
        XCTAssertEqual(Set(models.map(\.artifact.fileName)).count, models.count)
        XCTAssertEqual(Set(models.map(\.name)).count, models.count)
    }

    func testEveryArtifactBuildsItsPinnedHuggingFaceURL() {
        for artifact in SpeechModelCatalog.models.map(\.artifact) + [SpeechModelCatalog.speechDetector] {
            let url = artifact.url
            XCTAssertEqual(url.scheme, "https")
            XCTAssertEqual(url.host, "huggingface.co")
            XCTAssertEqual(url.path, "/\(artifact.repository)/resolve/\(artifact.revision)/\(artifact.fileName)")
        }
        XCTAssertEqual(
            try model("parakeet_v3").artifact.url.absoluteString,
            "https://huggingface.co/handy-computer/parakeet-tdt-0.6b-v3-gguf/resolve/"
                + "85ac09ea12fc4b1112fa76810059364bc6adc9de/parakeet-tdt-0.6b-v3-Q8_0.gguf")
    }

    func testCatalogHoldsEverySeventeenEntryOfHexInItsOrder() {
        XCTAssertEqual(SpeechModelCatalog.models.map(\.id), [
            "parakeet_unified_en", "parakeet_v2", "parakeet_v3", "orukeet", "whisper_large_v3_turbo", "qwen3_asr06_b",
            "qwencleo_asr_1_7b", "ivrit_whisper_large_v3_turbo", "sense_voice_small", "cohere_transcribe",
            "underdog_bark_3_pro", "underdog_bark_3_clean", "parakeet_ultra", "nemotron_3_5_asr", "gigaam_v3",
            "nb_whisper_medium", "granite_speech_5"
        ])
        XCTAssertNil(SpeechModelCatalog.model(id: "apple_speech"))
        XCTAssertNil(SpeechModelCatalog.model(id: "unknown"))
    }

    func testSingleLanguageModelsReportIt() throws {
        XCTAssertTrue(try model("gigaam_v3").isSingleLanguage)
        XCTAssertTrue(try model("parakeet_v2").languages.isSingleLanguage)
        XCTAssertFalse(try model("parakeet_v3").isSingleLanguage)
        XCTAssertTrue(try model("parakeet_v3").languages.supports("de"))
        XCTAssertFalse(try model("parakeet_v3").languages.supports("ja"))
    }

    /// Hex names a licence for ten entries; the other seven carry the one their model card declares.
    func testEveryEntryNamesItsLicence() throws {
        XCTAssertEqual(SpeechModelCatalog.models.filter { !$0.license.isRecorded }.map(\.id), [])
        XCTAssertEqual(try model("orukeet").license.name, "CC-BY-SA-4.0")
        XCTAssertEqual(try model("nemotron_3_5_asr").license.name, "OpenMDW-1.1")
        XCTAssertEqual(try model("parakeet_unified_en").license.name, "NVIDIA Open Model License")
        XCTAssertEqual(try model("sense_voice_small").license.name, "FunASR Model License")
    }

    // MARK: Hex's tests

    func testOrukeetIsOfferedForExactlyParakeetV3sLanguagesAndNeverBadged() throws {
        let orukeet = try model("orukeet")
        let v3 = try model("parakeet_v3")
        XCTAssertEqual(orukeet.languages, .many(SpeechModelCatalog.parakeetV3Languages))
        XCTAssertEqual(orukeet.languageChoices, v3.languageChoices)
        XCTAssertFalse(orukeet.streams)
        XCTAssertFalse(orukeet.acceptsLanguageHint)
        XCTAssertTrue(orukeet.supportsLanguageDetection)
        for language in v3.languages.codes + [SpeechLanguage.auto] {
            XCTAssertTrue(
                SpeechModelCatalog.choices(for: language).allSatisfy { $0.model.id != orukeet.id },
                "Orukeet is never recommended (\(language))")
        }
    }

    func testParakeetUltraIsOfferedOnlyWithItsLabAndASavedChoiceSurvives() throws {
        // Hex gates Ultra behind a Labs switch; here it is an ordinary entry, so only the rest carries over.
        let ultra = try model("parakeet_ultra")
        XCTAssertFalse(ultra.streams)
        XCTAssertFalse(ultra.acceptsLanguageHint)
        XCTAssertEqual(ultra.languages, .many(SpeechModelCatalog.parakeetV3Languages))
        for language in [SpeechLanguage.auto, "en", "de"] {
            XCTAssertTrue(
                SpeechModelCatalog.choices(for: language).allSatisfy { $0.model.id != ultra.id },
                "Ultra is never recommended (\(language))")
        }
        XCTAssertNoThrow(try SpeechModelCatalog.validate(SpeechModelSelection(modelID: ultra.id, language: "de")))
    }

    func testGgufArtifactsAreQ80ForTheVulkanShaderSubset() {
        // Hex's Q8_0 files hold only the tensor types its Vulkan backend is built for; NB-Whisper's whisper.cpp
        // file is q5_0. The check keeps a new quantization from slipping in unnoticed.
        for model in SpeechModelCatalog.models {
            let name = model.artifact.fileName
            XCTAssertTrue(name.hasSuffix("-Q8_0.gguf") || name == "ggml-model-q5_0.bin", name)
        }
    }

    func testOnlyTheStreamingParakeetArtifactsAreMarkedStreaming() {
        // transcribe.cpp advertises streaming for Parakeet's chunked-attention (Unified English) and cache-aware
        // (Nemotron 3.5) variants; the rest transcribe whole clips.
        XCTAssertEqual(
            SpeechModelCatalog.models.filter(\.streams).map(\.variant),
            ["unified-en-0.6b", "nemotron-3.5-asr-streaming-0.6b"])
        XCTAssertEqual(
            try model("parakeet_unified_en").streamingChunk,
            SpeechModelStreamingChunk(leftMilliseconds: 5600, chunkMilliseconds: 1040, rightMilliseconds: 1040))
    }

    func testModelIdsHaveExplicitStableWireNames() throws {
        let names: [(String, String)] = [
            ("parakeet_unified_en", "Parakeet Unified English"), ("parakeet_v2", "Parakeet v2"),
            ("parakeet_v3", "Parakeet v3"), ("orukeet", "Orukeet"),
            ("whisper_large_v3_turbo", "Whisper large-v3-turbo"), ("qwen3_asr06_b", "Qwen3-ASR 0.6B"),
            ("qwencleo_asr_1_7b", "QwenCleo-ASR 1.7B"),
            ("ivrit_whisper_large_v3_turbo", "ivrit.ai Whisper large-v3-turbo"),
            ("sense_voice_small", "SenseVoice Small"), ("cohere_transcribe", "Cohere Transcribe"),
            ("underdog_bark_3_pro", "Underdog Bark 3.0 Pro"), ("underdog_bark_3_clean", "Underdog Bark 3.0 Clean"),
            ("parakeet_ultra", "Parakeet Ultra"), ("nemotron_3_5_asr", "Nemotron 3.5 ASR"),
            ("gigaam_v3", "GigaAM v3"), ("nb_whisper_medium", "NB-Whisper Medium"),
            ("granite_speech_5", "Granite Speech 5.0")
        ]
        for (id, name) in names {
            XCTAssertEqual(try model(id).id, id)
            XCTAssertEqual(try model(id).name, name)
        }
        XCTAssertEqual(names.count, SpeechModelCatalog.models.count)
        XCTAssertNil(SpeechModelCatalog.model(id: "unknown"))
    }

    func testWhisperAndQwen3AsrReadTheVocabularyAsAPromptAndParakeetBiases() {
        func by(_ use: SpeechModelVocabularyUse) -> [String] {
            SpeechModelCatalog.models.filter { $0.vocabularyUse == use }.map(\.id)
        }
        XCTAssertEqual(by(.prompt), [
            "whisper_large_v3_turbo", "qwen3_asr06_b", "qwencleo_asr_1_7b", "ivrit_whisper_large_v3_turbo",
            "nb_whisper_medium"
        ])
        XCTAssertEqual(by(.bias), [
            "parakeet_unified_en", "parakeet_v2", "parakeet_v3", "orukeet", "underdog_bark_3_pro",
            "underdog_bark_3_clean", "parakeet_ultra", "nemotron_3_5_asr"
        ])
    }

    func testSpeechDetectorArtifactDownloadsFromItsPinnedRevision() {
        XCTAssertEqual(
            SpeechModelCatalog.speechDetector.url.absoluteString,
            "https://huggingface.co/handy-computer/silero-vad-v6.2-gguf/resolve/"
                + "a9b2d61c20ae4ddf3644edb34969e8185a485448/silero-vad-v6.2-F32.gguf")
        XCTAssertEqual(SpeechModelCatalog.speechDetector.byteCount, 1_241_056)
    }

    func testCohereChunksAtReferenceWindowNotEncoderCapacity() {
        typealias Catalog = SpeechModelCatalog
        XCTAssertEqual(Catalog.maxAudioChunkSamples(architecture: .cohereASR, maxAudioMilliseconds: 400_000), 560_000)
        XCTAssertEqual(Catalog.maxAudioChunkSamples(architecture: .cohereASR, maxAudioMilliseconds: 0), 560_000)
        XCTAssertEqual(Catalog.maxAudioChunkSamples(architecture: .cohereASR, maxAudioMilliseconds: 10_000), 160_000)
        XCTAssertNil(Catalog.maxAudioChunkSamples(architecture: .whisper, maxAudioMilliseconds: 0))
        XCTAssertEqual(Catalog.maxAudioChunkSamples(architecture: .parakeet, maxAudioMilliseconds: 60_000), 960_000)
    }
}
