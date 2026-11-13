import XCTest
@testable import OopsCore

/// Hex's filler word tests (`src/dictation/filler_words.rs` at v3.4.0), each under its upstream name in the Swift
/// style, and the same cases in French.
final class CleanupFillerWordsTests: XCTestCase {
    func testOnlyEnglishAndFrenchDictationsApplyTheFilter() {
        // Hex's filter applies to English alone; French joins it here.
        XCTAssertTrue(FillerWords.applies(to: "en"))
        XCTAssertTrue(FillerWords.applies(to: "fr"))
        for language in ["de", "pt", "auto", ""] { XCTAssertFalse(FillerWords.applies(to: language), language) }
    }

    func testFillersLeaveWithTheirCommasAndSpaces() {
        XCTAssertEqual(FillerWords.apply("So, um, we should go."), "So, we should go.")
        XCTAssertEqual(FillerWords.apply("I think uh we should go."), "I think we should go.")
        XCTAssertEqual(FillerWords.apply("I think, um."), "I think.")
        XCTAssertEqual(FillerWords.apply("Well umm... maybe"), "Well maybe")
        XCTAssertEqual(FillerWords.apply("It was, er, erm, fine"), "It was, fine")
        XCTAssertEqual(FillerWords.apply("Done, uh"), "Done")
        XCTAssertEqual(FillerWords.apply("(um, aside)"), "(aside)")
    }

    func testAFillerThatStartedASentenceHandsOnItsCapital() {
        XCTAssertEqual(FillerWords.apply("Um, so I think"), "So I think")
        XCTAssertEqual(FillerWords.apply("Hello. Uh, we left. Ah. Then"), "Hello. We left. Then")
        XCTAssertEqual(FillerWords.apply("Uh, um, okay"), "Okay")
    }

    func testLineBreaksAreKept() {
        XCTAssertEqual(FillerWords.apply("First line.\nUm, second"), "First line.\nSecond")
        XCTAssertEqual(FillerWords.apply("one um\ntwo"), "one\ntwo")
    }

    func testOtherWordsAreLeftAlone() {
        for text in [
            "The umbrella is ahead of the error.", "Uhura said uh-huh.", "Take him to the ER.", "UM is a university.",
            "drum, Ahab, ermine", "Plain text, nothing to do.", ""
        ] {
            XCTAssertEqual(FillerWords.apply(text), text)
        }
    }

    // MARK: French

    func testFrenchFillersLeaveWithTheirCommasAndSpaces() {
        XCTAssertEqual(FillerWords.apply("Alors, euh, on y va."), "Alors, on y va.")
        XCTAssertEqual(FillerWords.apply("Je pense bah qu'on y va."), "Je pense qu'on y va.")
        XCTAssertEqual(FillerWords.apply("Je pense, hum."), "Je pense.")
        XCTAssertEqual(FillerWords.apply("Eh bien euh... peut-être"), "Eh bien peut-être")
        XCTAssertEqual(FillerWords.apply("C'était, euh, hum, correct"), "C'était, correct")
        XCTAssertEqual(FillerWords.apply("Terminé, euh"), "Terminé")
    }

    func testAFrenchFillerThatStartedASentenceHandsOnItsCapital() {
        XCTAssertEqual(FillerWords.apply("Euh, donc je pense"), "Donc je pense")
        XCTAssertEqual(FillerWords.apply("Bonjour. Bah, on est partis. Hum. Puis"), "Bonjour. On est partis. Puis")
        XCTAssertEqual(FillerWords.apply("Euh, bah, d'accord"), "D'accord")
        XCTAssertEqual(FillerWords.apply("Première ligne.\nEuh, deuxième"), "Première ligne.\nDeuxième")
    }

    func testOtherFrenchWordsAreLeftAlone() {
        for text in ["Humberto a heurté l'humeur.", "Un bahut, des euhéméristes.", "Bien sûr, tout va bien.", "Le hummus"] {
            XCTAssertEqual(FillerWords.apply(text), text)
        }
    }
}
