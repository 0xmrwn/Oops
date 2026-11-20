import XCTest
@testable import OopsCore

/// What the speech model picker shows for a language, read from the catalog.
final class SpeechModelPickerTests: XCTestCase {
    private typealias Catalog = SpeechModelCatalog

    func testEnglishShowsItsThreePicksThenTheOtherEnglishModelsThenTheRest() {
        let picks = SpeechModelPicks(language: "en")
        XCTAssertEqual(picks.picks.map(\.model.id), ["parakeet_unified_en", "cohere_transcribe", "whisper_large_v3_turbo"])
        XCTAssertEqual(picks.picks.map(\.recommendation), [.recommended, .mostAccurate, .vocabulary])
        XCTAssertTrue(picks.others.allSatisfy { $0.supports(language: "en") })
        XCTAssertEqual(picks.elsewhere.map(\.id), ["qwencleo_asr_1_7b", "gigaam_v3", "nb_whisper_medium"])
        XCTAssertEqual(picks.picks.count + picks.others.count + picks.elsewhere.count, Catalog.models.count)
    }

    func testTheLeadingPickOnEachFactIsTheOneShownStronger() {
        let picks = SpeechModelPicks(language: "en")
        XCTAssertEqual(picks.shortestWait, "parakeet_unified_en")
        XCTAssertEqual(picks.mostAccurate, "cohere_transcribe")
        XCTAssertEqual(picks.mostLanguages, "whisper_large_v3_turbo")
    }

    func testOnePickOrATieLeadsOnNothing() {
        let one = SpeechModelPicks(language: "tr")
        XCTAssertEqual(one.picks.map(\.model.id), ["whisper_large_v3_turbo"])
        XCTAssertNil(one.mostAccurate)
        XCTAssertNil(one.shortestWait)
        // Korean's two picks both take seconds.
        XCTAssertNil(SpeechModelPicks(language: "ko").shortestWait)
    }

    func testAPickTheStoreDoesNotCarryIsLeftOut() {
        let picks = SpeechModelPicks(language: "en", models: [Catalog.parakeetV2, Catalog.whisperLargeV3Turbo])
        XCTAssertEqual(picks.picks.map(\.model.id), ["whisper_large_v3_turbo"])
        XCTAssertEqual(picks.others.map(\.id), ["parakeet_v2"])
    }

    func testWaitComesFromStreamingThenHexsSpeedLabel() {
        XCTAssertEqual(Catalog.parakeetUnifiedEnglish.wait, .live)
        XCTAssertEqual(Catalog.nemotron35ASR.wait, .live)
        XCTAssertEqual(Catalog.parakeetV3.wait, .underASecond)
        XCTAssertEqual(Catalog.cohereTranscribe.wait, .underASecond)
        XCTAssertEqual(Catalog.whisperLargeV3Turbo.wait, .seconds)
        XCTAssertEqual([SpeechModelWait.live, .underASecond, .seconds].map(\.label), ["Live", "< 1 s", "2 s"])
    }

    func testFactsReadAsThePickerPrintsThem() throws {
        XCTAssertEqual(try XCTUnwrap(Catalog.cohereTranscribe.accuracy), 98.73, accuracy: 0.001)
        XCTAssertEqual(Catalog.parakeetUnifiedEnglish.downloadSize, "731 MB")
        // The decimal mark follows the Mac's region.
        XCTAssertEqual(Catalog.cohereTranscribe.downloadSize.filter(\.isNumber), "241")
        XCTAssertTrue(Catalog.cohereTranscribe.downloadSize.hasSuffix(" GB"))
        XCTAssertEqual(Catalog.parakeetUnifiedEnglish.languageSummary, "English")
        XCTAssertEqual(Catalog.parakeetV3.languageSummary, "25 languages")
        XCTAssertEqual(Catalog.whisperLargeV3Turbo.page?.absoluteString, "https://huggingface.co/\(Catalog.whisperLargeV3Turbo.artifact.repository)")
    }

    func testOnlyTheMakersOwnModelsCarryAMark() {
        let marked = Dictionary(uniqueKeysWithValues: Catalog.models.compactMap { model in model.maker.map { (model.id, $0) } })
        XCTAssertEqual(marked, [
            "parakeet_unified_en": .nvidia, "parakeet_v2": .nvidia, "parakeet_v3": .nvidia, "nemotron_3_5_asr": .nvidia,
            "whisper_large_v3_turbo": .openAI, "cohere_transcribe": .cohere, "qwen3_asr06_b": .qwen,
            "sense_voice_small": .alibaba, "granite_speech_5": .ibm,
        ])
    }
}
