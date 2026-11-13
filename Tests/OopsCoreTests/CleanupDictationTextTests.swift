import XCTest
@testable import OopsCore

/// A transcript's local way to the caret: vocabulary first, then the small cleanups.
final class CleanupDictationTextTests: XCTestCase {
    func testWithNothingOnTheTranscriptComesBackByteForByte() {
        for text in ["Um, hello comma new line there", "", "a\r\nb", "Ünïcödé \u{1F600}"] {
            for language in [nil, "en", "fr", "auto"] {
                let result = DictationText.prepare(text, vocabulary: nil, cleanups: .off, language: language)
                XCTAssertEqual(Array(result.utf8), Array(text.utf8))
            }
        }
    }

    func testEachSwitchOffLeavesItsOwnCleanupUndone() {
        let text = "Um, hello comma new line there"
        let fillersOff = SmallCleanups(fillers: false, formatting: true, symbols: true)
        XCTAssertEqual(DictationText.prepare(text, vocabulary: nil, cleanups: fillersOff, language: "en"), "Um, hello,\nthere")
        let formattingOff = SmallCleanups(fillers: true, formatting: false, symbols: true)
        XCTAssertEqual(DictationText.prepare(text, vocabulary: nil, cleanups: formattingOff, language: "en"), "Hello, new line there")
        let symbolsOff = SmallCleanups(fillers: true, formatting: true, symbols: false)
        XCTAssertEqual(DictationText.prepare(text, vocabulary: nil, cleanups: symbolsOff, language: "en"), "Hello comma\nthere")
    }

    func testFillersGoOnlyInEnglishAndFrench() {
        let fillers = SmallCleanups(fillers: true)
        XCTAssertEqual(DictationText.prepare("Euh, oui", vocabulary: nil, cleanups: fillers, language: "fr"), "Oui")
        XCTAssertEqual(DictationText.prepare("Um, yes", vocabulary: nil, cleanups: fillers, language: "en-GB"), "Yes")
        for language in [nil, "auto", "de", "pt"] {
            XCTAssertEqual(DictationText.prepare("Um, ja", vocabulary: nil, cleanups: fillers, language: language), "Um, ja")
        }
    }

    func testFuzzyReplacementRunsBeforeTheCleanupsSoTheirLineBreaksStay() {
        let all = SmallCleanups(fillers: true, formatting: true, symbols: true)
        let result = DictationText.prepare("open tail scale new line ghosty comma done", vocabulary: .fuzzyReplacement(["Tailscale", "Ghostty"]),
                                           cleanups: all, language: "en")
        XCTAssertEqual(result, "open Tailscale\nGhostty, done")
    }

    func testAnEnginesOwnVocabularyIsNotAppliedAgainAfterIt() {
        let text = "open tail scale"
        let bias = VocabularyBias(terms: ["Tailscale"], soundsLike: [], boost: 2.5)
        for delivery: VocabularyDelivery in [.parakeetBias(bias), .prompt("Tailscale"), .openAIKeywords(["Tailscale"])] {
            XCTAssertEqual(DictationText.prepare(text, vocabulary: delivery, cleanups: .off, language: "en"), text)
        }
    }
}
