@testable import OopsCore
import XCTest

/// The dictation language first run infers, and the model that follows from it.
final class SpeechLanguageFirstRunTests: XCTestCase {
    func testOneKeyboardFollowsTheSystemLanguage() {
        XCTAssertEqual(SpeechLanguage.firstRun(preferred: ["en-GB", "fr-FR"], keyboards: [["en", "af"]]), "en")
        XCTAssertEqual(SpeechLanguage.firstRun(preferred: ["fr-FR"], keyboards: [["fr"]]), "fr")
        XCTAssertEqual(SpeechLanguage.firstRun(preferred: ["zh_Hans_CN"], keyboards: []), "zh")
    }

    func testKeyboardsInSeveralLanguagesMeanAuto() {
        XCTAssertEqual(SpeechLanguage.firstRun(preferred: ["en-US"], keyboards: [["en"], ["fr"]]), SpeechLanguage.auto)
        XCTAssertEqual(SpeechLanguage.firstRun(preferred: ["en-US"], keyboards: [["en"], ["en-GB"]]), "en", "two layouts, one language")
    }

    func testAnUnlistedOrMissingLanguageFallsBackToEnglish() {
        XCTAssertEqual(SpeechLanguage.firstRun(preferred: ["tlh"], keyboards: []), "en")
        XCTAssertEqual(SpeechLanguage.firstRun(preferred: [], keyboards: []), "en")
    }

    func testTheGuessPicksTheRecommendedModel() {
        XCTAssertEqual(SpeechModelCatalog.recommendedSelection(for: SpeechLanguage.firstRun(preferred: ["en-US"], keyboards: [])).modelID,
                       SpeechModelCatalog.parakeetUnifiedEnglish.id)
        XCTAssertEqual(SpeechModelCatalog.recommendedSelection(for: SpeechLanguage.auto).modelID, SpeechModelCatalog.whisperLargeV3Turbo.id)
    }
}
