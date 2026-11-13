import XCTest
@testable import OopsCore

final class DictateSelectionTests: XCTestCase {
    private struct Languages: SpeechLanguageSupport {
        let codes: [String]
        func supports(_ code: String) -> Bool { codes.contains(code) }
        var isSingleLanguage: Bool { codes.count == 1 }
    }

    private let whisper = Languages(codes: ["en", "fr", "de"]), english = Languages(codes: ["en"])

    func testSwitchingKeepsALanguageTheNewModelSupports() {
        var selection = DictateSelection(model: .local("whisper-small"), language: "fr")
        selection.switchModel(to: .local("whisper-large"), languages: whisper)
        XCTAssertEqual(selection, DictateSelection(model: .local("whisper-large"), language: "fr"))
    }

    func testSwitchingToAModelWithoutTheLanguageGivesAutomatic() {
        var selection = DictateSelection(model: .local("whisper-large"), language: "fr")
        selection.switchModel(to: .local("parakeet-unified-en"), languages: english)
        XCTAssertEqual(selection, DictateSelection(model: .local("parakeet-unified-en"), language: nil))
        // Back on a model that has French, Automatic stays: the choice was given up, not remembered.
        selection.switchModel(to: .local("whisper-large"), languages: whisper)
        XCTAssertNil(selection.language)
    }

    func testASingleLanguageModelKeepsOnlyItsOwnLanguage() {
        XCTAssertTrue(english.isSingleLanguage)
        var selection = DictateSelection(model: .local("whisper-large"), language: "en")
        selection.switchModel(to: .local("parakeet-unified-en"), languages: english)
        XCTAssertEqual(selection.language, "en")
        selection.language = "de"
        selection.switchModel(to: .local("parakeet-unified-en"), languages: english)
        XCTAssertNil(selection.language)
    }

    func testAModelWithUnknownLanguagesKeepsTheChoice() {
        let choice = ModelSelection.Choice(providerID: "groq-id", modelID: "whisper-large-v3")
        var selection = DictateSelection(model: .local("whisper-large"), language: "fr")
        selection.switchModel(to: .provider(choice), languages: nil)
        XCTAssertEqual(selection, DictateSelection(model: .provider(choice), language: "fr"))
        XCTAssertEqual(try JSONDecoder().decode(DictateSelection.self, from: JSONEncoder().encode(selection)), selection)
    }

    func testFeaturesKeepTheirChoicesUnderTheirOwnKeys() {
        XCTAssertEqual(ModelFeature.fix.preferenceKey, "modelSelection")
        XCTAssertEqual(ModelFeature.dictate.preferenceKey, "dictateSelection")
        let voice = ModelCapabilities(text: false, voice: true, source: .name), text = ModelCapabilities(text: true, voice: false, source: .name)
        XCTAssertEqual(ModelFeature.allCases.map { $0.accepts(voice) }, [false, true, false])
        XCTAssertEqual(ModelFeature.allCases.map { $0.accepts(text) }, [true, false, true])
    }
}
