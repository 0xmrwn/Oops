import XCTest
@testable import OopsCore

/// The entry point that applies the enabled small cleanups in order.
final class CleanupTranscriptTests: XCTestCase {
    let messy = "Um, so new line hashtag release comma euh nouveau paragraphe  \tdone,   COMMA  thanks\r\n open quote x close quote "

    func testWithAllThreeOffTheTranscriptComesBackByteForByte() {
        for text in [messy, "", "  ", "Plain text.", "Ünïcödé \u{1F600} e\u{301}", "a\u{0}b"] {
            let result = TranscriptCleanup.apply(text, fillers: false, formatting: false, symbols: false)
            XCTAssertEqual(Array(result.utf8), Array(text.utf8))
        }
    }

    func testEachSwitchRunsOnlyItsOwnCleanup() {
        let text = "Um, hello comma new line there"
        XCTAssertEqual(TranscriptCleanup.apply(text, fillers: true, formatting: false, symbols: false), "Hello comma new line there")
        XCTAssertEqual(TranscriptCleanup.apply(text, fillers: false, formatting: true, symbols: false), "Um, hello comma\nthere")
        XCTAssertEqual(TranscriptCleanup.apply(text, fillers: false, formatting: false, symbols: true), "Um, hello, new line there")
    }

    func testTheCleanupsRunInTheOrderFillersFormattingSymbols() {
        XCTAssertEqual(
            TranscriptCleanup.apply("Um, hello comma new line there", fillers: true, formatting: true, symbols: true),
            "Hello,\nthere"
        )
        XCTAssertEqual(
            TranscriptCleanup.apply("Euh, bonjour virgule à la ligne merci", fillers: true, formatting: true, symbols: true),
            "Bonjour,\nmerci"
        )
    }
}
