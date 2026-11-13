import XCTest
@testable import OopsCore

/// Hex's tests of the catalog's language rules and per-language routing (`src/transcription/models.rs` at
/// v3.4.0), each under its upstream name in the Swift style.
final class ModelCatalogLanguageTests: XCTestCase {
    private typealias Catalog = SpeechModelCatalog

    private struct Route: Equatable {
        let id: String
        let recommendation: SpeechModelRecommendation

        init(_ id: String, _ recommendation: SpeechModelRecommendation) {
            self.id = id
            self.recommendation = recommendation
        }
    }

    private let whisper = "whisper_large_v3_turbo"
    private let qwen = "qwen3_asr06_b"
    private let cohere = "cohere_transcribe"
    private let v3 = "parakeet_v3"
    private let senseVoice = "sense_voice_small"

    private func model(_ id: String, file: StaticString = #filePath, line: UInt = #line) throws -> SpeechModel {
        try XCTUnwrap(Catalog.model(id: id), file: file, line: line)
    }

    private func routing(_ language: String) -> [Route] {
        Catalog.choices(for: language).map { Route($0.model.id, $0.recommendation) }
    }

    private func selection(_ model: String, _ language: String) -> SpeechModelSelection {
        SpeechModelSelection(modelID: model, language: language)
    }

    func testHebrewRecommendsTheIvritFineTuneWithItsHint() throws {
        XCTAssertEqual(routing("he"), [Route("ivrit_whisper_large_v3_turbo", .recommended), Route(whisper, .vocabulary)])
        let ivrit = try model("ivrit_whisper_large_v3_turbo")
        XCTAssertEqual(ivrit.languageChoices, ["he"])
        XCTAssertEqual(ivrit.runtimeLanguageHint(for: "he"), "he")
        XCTAssertFalse(ivrit.supports(language: SpeechLanguage.auto))
        XCTAssertEqual(SpeechLanguage.name(of: "he"), "Hebrew")
    }

    func testAnImportOffersEveryLanguageItDeclaresByName() throws {
        // Hex builds the import from Whisper's definition with its own languages; so does this.
        let base = try model(whisper)
        let importedModel = SpeechModel(
            id: "import", name: "Import", artifact: base.artifact, architecture: base.architecture, variant: base.variant,
            languages: .many(["en", "nn", "no"]), acceptsLanguageHint: true, supportsLanguageDetection: true,
            wordErrorRate: nil, realtime: "")
        XCTAssertEqual(importedModel.languageChoices, [SpeechLanguage.auto, "en", "no", "nn"])
        XCTAssertEqual(SpeechLanguage.name(of: "nn"), "Norwegian Nynorsk")
        XCTAssertFalse(base.languageChoices.contains("nn"))
    }

    func testNorwegianRecommendsNbWhisperWithItsHint() throws {
        XCTAssertEqual(routing("no"), [Route("nb_whisper_medium", .recommended), Route(whisper, .vocabulary)])
        let nb = try model("nb_whisper_medium")
        XCTAssertEqual(nb.languageChoices, ["no"])
        XCTAssertEqual(nb.runtimeLanguageHint(for: "no"), "no")
        XCTAssertFalse(nb.supports(language: SpeechLanguage.auto))
        XCTAssertTrue(try model(whisper).languageChoices.contains("no"))
        XCTAssertEqual(SpeechLanguage.name(of: "no"), "Norwegian")
    }

    func testRussianRecommendsGigaamWithoutAHint() throws {
        XCTAssertEqual(routing("ru"), [Route("gigaam_v3", .recommended), Route(whisper, .vocabulary)])
        let gigaam = try model("gigaam_v3")
        XCTAssertEqual(gigaam.languageChoices, ["ru"])
        XCTAssertNil(gigaam.runtimeLanguageHint(for: "ru"))
        XCTAssertEqual(gigaam.vocabularyUse, .none)
    }

    func testRecommendationsAreLanguageSpecific() {
        let english = Catalog.choices(for: "en")
        XCTAssertEqual(english[0].model.id, "parakeet_unified_en")
        XCTAssertEqual(english[0].recommendation, .recommended)
        XCTAssertEqual(english[1].model.id, cohere)
        XCTAssertEqual(english[1].recommendation, .mostAccurate)
        let mandarin = Catalog.choices(for: "zh")
        XCTAssertEqual(mandarin[0].model.id, qwen)
        XCTAssertEqual(mandarin[1].model.id, senseVoice)
    }

    func testEveryLanguageHasExactlyOneRecommendedModel() {
        for (language, _) in SpeechLanguage.listed {
            let recommended = Catalog.choices(for: language).filter { $0.recommendation == .recommended }.map(\.model.id)
            XCTAssertEqual(recommended.count, 1, "\(language): \(recommended)")
            XCTAssertEqual(Catalog.recommendedSelection(for: language).modelID, recommended.first, language)
        }
    }

    func testWhisperAcceptsItsLanguagesBeyondTheSettingsList() {
        for language in ["ta", "te"] {
            XCTAssertNoThrow(try Catalog.validate(selection(whisper, language)), language)
            XCTAssertThrowsError(try Catalog.validate(selection(qwen, language)), language)
        }
        XCTAssertThrowsError(try Catalog.validate(selection(whisper, "xx")))
    }

    func testNemotronTakesItsLanguagesAsLocalesAndDetectsWithAuto() throws {
        let nemotron = try model("nemotron_3_5_asr")
        XCTAssertEqual(nemotron.runtimeLanguageHint(for: "de"), "de-DE")
        XCTAssertEqual(nemotron.runtimeLanguageHint(for: "zh"), "zh-CN")
        XCTAssertNil(nemotron.runtimeLanguageHint(for: SpeechLanguage.auto))
        XCTAssertTrue(nemotron.supports(language: SpeechLanguage.auto))
        // Every language it offers has its locale.
        for language in nemotron.languages.codes {
            XCTAssertNotNil(nemotron.runtimeLanguages[language], language)
        }
        XCTAssertTrue(nemotron.languages.codes.allSatisfy(SpeechLanguage.isListed))
    }

    func testSelectionsRequireModelLanguageCompatibility() {
        XCTAssertNoThrow(try Catalog.validate(selection("parakeet_unified_en", "en")))
        XCTAssertThrowsError(try Catalog.validate(selection("parakeet_v2", "zh")))
        XCTAssertThrowsError(try Catalog.validate(selection("parakeet_v2", SpeechLanguage.auto)))
        XCTAssertNoThrow(try Catalog.validate(selection(whisper, SpeechLanguage.auto)))
        XCTAssertThrowsError(try Catalog.validate(selection("apple_speech", "en")))
    }

    func testModelsThatDetectLanguageWithoutAHintOfferAuto() throws {
        for id in [v3, "granite_speech_5"] {
            let definition = try model(id)
            XCTAssertFalse(definition.acceptsLanguageHint, id)
            XCTAssertTrue(definition.supportsLanguageDetection, id)
            XCTAssertTrue(definition.languageChoices.contains(SpeechLanguage.auto))
            XCTAssertEqual(definition.language(for: SpeechLanguage.auto), SpeechLanguage.auto)
        }
        let v2 = try model("parakeet_v2")
        XCTAssertFalse(v2.supportsLanguageDetection)
        XCTAssertFalse(v2.languageChoices.contains(SpeechLanguage.auto))
        XCTAssertEqual(v2.language(for: SpeechLanguage.auto), "en")
    }

    func testAutomaticLanguageChoicesOnlyIncludeDetectionModels() {
        let choices = Catalog.choices(for: SpeechLanguage.auto)
        XCTAssertFalse(choices.isEmpty)
        XCTAssertTrue(choices.allSatisfy(\.model.supportsLanguageDetection))
        XCTAssertTrue(choices.contains { $0.model.id == qwen })
        XCTAssertTrue(choices.allSatisfy { $0.model.id != senseVoice })
    }

    func testWeakQwenAndParakeetLanguagesRouteToStrongerShippedModels() {
        XCTAssertEqual(routing("el"), [Route(cohere, .recommended), Route(whisper, .vocabulary)])
        for language in ["tr", "ms", "fil", "fa", "mk"] {
            XCTAssertEqual(routing(language), [Route(whisper, .recommended)])
        }
        XCTAssertEqual(routing("ar"), [Route(whisper, .recommended), Route(cohere, .mostAccurate)])
        for language in ["fi", "sv", "da"] {
            XCTAssertEqual(routing(language), [Route(whisper, .recommended), Route(v3, .fastest)])
        }
        XCTAssertEqual(routing("ja"), [Route(whisper, .recommended), Route(senseVoice, .fastest)])
        XCTAssertEqual(routing(SpeechLanguage.auto), [Route(whisper, .recommended), Route(qwen, .fastest)])
        for language in ["yue", "ko"] {
            XCTAssertEqual(routing(language), [Route(qwen, .recommended), Route(whisper, .vocabulary)])
        }
        XCTAssertEqual(routing("vi"), [Route(qwen, .recommended), Route(cohere, .mostAccurate), Route(whisper, .vocabulary)])
        XCTAssertEqual(routing("mt"), [Route(v3, .recommended)])
        for language in ["hi", "th", "id", "zh"] {
            XCTAssertEqual(routing(language).first, Route(qwen, .recommended))
        }
        XCTAssertEqual(routing("de").first, Route(v3, .recommended))
    }

    func testEveryLanguageChoiceSupportsItsLanguageAndFirstRunPicksIt() {
        for (language, _) in SpeechLanguage.listed {
            let choices = Catalog.choices(for: language)
            XCTAssertFalse(choices.isEmpty, language)
            for choice in choices {
                XCTAssertTrue(choice.model.supports(language: language), language)
            }
            XCTAssertNoThrow(try Catalog.validate(Catalog.recommendedSelection(for: language)), language)
        }
        XCTAssertEqual(Catalog.recommendedSelection(for: "el").modelID, cohere)
        XCTAssertEqual(Catalog.recommendedSelection(for: "tr").modelID, whisper)
    }

    func testThePickerListsEveryModelWithTheLanguageSRecommendationsFirst() {
        for (language, _) in SpeechLanguage.listed {
            XCTAssertEqual(Catalog.picker(for: language).count, Catalog.models.count, language)
        }
        let greek = Catalog.picker(for: "el")
        XCTAssertEqual(greek[0].model.id, cohere)
        XCTAssertEqual(greek[0].recommendation, .recommended)
        XCTAssertEqual(greek[1].model.id, whisper)
        XCTAssertEqual(greek[1].recommendation, .vocabulary)
        // Then Parakeet v3, which supports Greek, before every model that would change the language.
        XCTAssertEqual(greek[2].model.id, v3)
        XCTAssertNil(greek[2].recommendation)
        let supports = greek.map { $0.model.supports(language: "el") }
        XCTAssertTrue(zip(supports, supports.dropFirst()).allSatisfy { $0 || !$1 })
        XCTAssertEqual(supports.last, false)
    }

    func testAModelSwitchKeepsASupportedLanguageOrFallsBackToTheModelSDefault() throws {
        let unified = try model("parakeet_unified_en")
        let whisperModel = try model(whisper)
        XCTAssertEqual(unified.language(for: "ja"), "en")
        XCTAssertEqual(unified.language(for: "auto"), "en")
        XCTAssertEqual(whisperModel.language(for: "ja"), "ja")
        XCTAssertEqual(whisperModel.language(for: "auto"), "auto")
        XCTAssertEqual(try model(qwen).language(for: "auto"), "auto")
        XCTAssertEqual(try model(cohere).language(for: "auto"), "en")
        for model in Catalog.models {
            for (language, _) in SpeechLanguage.listed {
                XCTAssertNoThrow(try Catalog.validate(selection(model.id, model.language(for: language))), "\(model.name) \(language)")
            }
        }
    }

    func testEachModelOffersExactlyTheLanguagesItSupports() throws {
        XCTAssertEqual(try model("parakeet_unified_en").languageChoices, ["en"])
        let whisperModel = try model(whisper)
        XCTAssertEqual(whisperModel.languageChoices.count, SpeechLanguage.listed.count)
        XCTAssertEqual(whisperModel.languageChoices[0], SpeechLanguage.auto)
        XCTAssertEqual(try model(senseVoice).languageChoices, ["auto", "en", "zh", "yue", "ja", "ko"])
        for model in Catalog.models {
            XCTAssertTrue(model.languageChoices.contains(model.defaultLanguage))
            // Hex skips the `"*"` entry's codes: Whisper takes more than Settings lists.
            let declared = model.languages == .anyKnown ? [] : model.languages.codes
            for code in declared {
                XCTAssertTrue(model.languageChoices.contains(code), "\(model.name) lists \(code) outside the listed languages")
            }
        }
    }

    func testRuntimeLanguageArgumentsDistinguishDetectionFromHints() throws {
        let whisperModel = try model(whisper)
        let qwenModel = try model(qwen)
        XCTAssertNil(whisperModel.runtimeLanguageHint(for: SpeechLanguage.auto))
        XCTAssertEqual(whisperModel.runtimeLanguageHint(for: "fil"), "tl")
        XCTAssertNil(qwenModel.runtimeLanguageHint(for: SpeechLanguage.auto))
        XCTAssertEqual(qwenModel.runtimeLanguageHint(for: "zh"), "zh")
    }

    func testParakeetV3SupportsPortugueseWithoutLanguageConditioning() throws {
        let chosen = try Catalog.validate(selection(v3, "pt"))
        XCTAssertEqual(chosen.id, v3)
        XCTAssertTrue(Catalog.choices(for: "pt").contains { $0.model.id == chosen.id })
        XCTAssertNil(chosen.runtimeLanguageHint(for: "pt"))
        XCTAssertEqual(try model(whisper).runtimeLanguageHint(for: "pt"), "pt")
        XCTAssertFalse(Catalog.choices(for: SpeechLanguage.auto).contains { $0.model.id == chosen.id })
    }

    func testBanglaIsTranscribedByWhisperWithItsLanguageHint() throws {
        let chosen = Catalog.recommendedSelection(for: "bn")
        XCTAssertEqual(chosen.modelID, whisper)
        XCTAssertEqual(chosen.language, "bn")
        let chosenModel = try Catalog.validate(chosen)
        XCTAssertEqual(chosenModel.runtimeLanguageHint(for: "bn"), "bn")
        let choices = Catalog.choices(for: "bn")
        XCTAssertEqual(choices.count, 1)
        XCTAssertEqual(choices[0].recommendation, .recommended)
        XCTAssertThrowsError(try Catalog.validate(selection(qwen, "bn")))
    }
}
