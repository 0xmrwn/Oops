import CoreGraphics
import XCTest
@testable import OopsCore

/// Where a dictation's live words go, and how a line of them is cut to fit. AX points, top-left origin.
final class LiveWordsAnchorTests: XCTestCase {
    private let field = CGRect(x: 100, y: 200, width: 600, height: 300)
    private let caret = CGRect(x: 300, y: 240, width: 1, height: 17)

    private func target(_ place: DictationLiveWordsPlace = .text, caret: CGRect?) -> LiveWordsTarget {
        LiveWordsAnchor.target(place, geometry: CapsulePlacement.Geometry(element: field, caret: caret))
    }

    func testTheDropSettingAlwaysUsesTheDrop() {
        XCTAssertEqual(target(.drop, caret: caret), .drop)
    }

    func testNoCaretFallsBackToTheDrop() {
        XCTAssertEqual(target(caret: nil), .drop)
        XCTAssertEqual(LiveWordsAnchor.target(.text, geometry: nil), .drop)
    }

    func testAPlaceholderOrWholeEditorCaretFallsBack() {
        // Chromium's zero-size answer, a caret as tall as the editor, and one as wide as a line.
        XCTAssertEqual(target(caret: CGRect(x: 300, y: 240, width: 0, height: 0)), .drop)
        XCTAssertEqual(target(caret: CGRect(x: 300, y: 200, width: 1, height: 300)), .drop)
        XCTAssertEqual(target(caret: CGRect(x: 100, y: 240, width: 400, height: 17)), .drop)
    }

    func testACaretOutsideItsFieldFallsBack() {
        XCTAssertEqual(target(caret: CGRect(x: 300, y: 700, width: 1, height: 17)), .drop)
    }

    func testTooLittleRoomBeforeTheEdgeFallsBack() {
        XCTAssertEqual(target(caret: CGRect(x: 600, y: 240, width: 1, height: 17)), .drop)
        // Without the field's frame, the window's edge counts.
        let geometry = CapsulePlacement.Geometry(element: nil, window: CGRect(x: 0, y: 0, width: 400, height: 600), caret: caret)
        XCTAssertEqual(LiveWordsAnchor.target(.text, geometry: geometry), .drop)
    }

    func testAGoodCaretGivesTheRoomToTheEdge() {
        XCTAssertEqual(target(caret: caret), .caret(caret, width: 399))
        let geometry = CapsulePlacement.Geometry(element: nil, window: CGRect(x: 0, y: 0, width: 1_000, height: 600), caret: caret)
        XCTAssertEqual(LiveWordsAnchor.target(.text, geometry: geometry), .caret(caret, width: 699))
    }

    // MARK: The line

    /// Ten points a character, so widths are easy to read.
    private func tail(_ words: LiveWords, _ width: CGFloat) -> LiveWords {
        words.tail(fitting: width) { CGFloat($0.count * 10) }
    }

    func testWordsThatFitAreKeptWhole() {
        XCTAssertEqual(tail(LiveWords(stable: " Hello", changing: " there"), 200), LiveWords(stable: "Hello", changing: " there"))
    }

    func testTheNewestWholeWordsAreKeptBehindAnEllipsis() {
        XCTAssertEqual(tail(LiveWords(stable: " one two three", changing: " four"), 120), LiveWords(stable: "…three", changing: " four"))
        XCTAssertEqual(tail(LiveWords(stable: " one two", changing: " three four"), 110), LiveWords(stable: "", changing: "…three four"))
    }

    func testTheLastWordStaysWhenNothingFits() {
        XCTAssertEqual(tail(LiveWords(stable: " one", changing: " extraordinary"), 30), LiveWords(stable: "", changing: "…extraordinary"))
    }
}
