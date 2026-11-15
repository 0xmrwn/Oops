import CoreGraphics
import XCTest
@testable import OopsCore

/// Where a dictation's live words go. AX points, top-left origin.
final class LiveWordsAnchorTests: XCTestCase {
    private let field = CGRect(x: 100, y: 200, width: 600, height: 300)
    private let caret = CGRect(x: 300, y: 240, width: 1, height: 17)

    /// A field that tells its text's colour, with nothing after the caret on its line.
    private let style = CaretStyle(color: SIMD3(0, 0, 0))

    private func target(_ place: DictationLiveWordsPlace = .text, caret: CGRect?) -> LiveWordsTarget {
        LiveWordsAnchor.target(place, geometry: CapsulePlacement.Geometry(element: field, caret: caret), style: style)
    }

    func testTheDropSettingAlwaysUsesTheDrop() {
        XCTAssertEqual(target(.drop, caret: caret), .drop)
    }

    func testNoCaretFallsBackToTheDrop() {
        XCTAssertEqual(target(caret: nil), .drop)
        XCTAssertEqual(LiveWordsAnchor.target(.text, geometry: nil, style: style), .drop)
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

    func testALineEndCaretOnTheLineAboveIsMovedBesideTheCharacterBeforeIt() {
        // TextEdit at the end of a line: the caret reported one line up, the character before it where it is drawn.
        let text = CGRect(x: 175, y: 132, width: 656, height: 384)
        let geometry = CapsulePlacement.Geometry(element: text, caret: CGRect(x: 304, y: 119, width: 0, height: 13),
                                                 previousCharacter: CGRect(x: 297, y: 133, width: 7, height: 13))
        XCTAssertEqual(LiveWordsAnchor.target(.text, geometry: geometry, style: style), .caret(CGRect(x: 304, y: 133, width: 0, height: 13), width: 527))
    }

    func testTooLittleRoomBeforeTheEdgeFallsBack() {
        XCTAssertEqual(target(caret: CGRect(x: 600, y: 240, width: 1, height: 17)), .drop)
        // Without the field's frame, the window's edge counts.
        let geometry = CapsulePlacement.Geometry(element: nil, window: CGRect(x: 0, y: 0, width: 400, height: 600), caret: caret)
        XCTAssertEqual(LiveWordsAnchor.target(.text, geometry: geometry, style: style), .drop)
    }

    func testAFieldThatTellsNothingOfItsTextFallsBack() {
        // No caret position, or a selection.
        let geometry = CapsulePlacement.Geometry(element: field, caret: caret)
        XCTAssertEqual(LiveWordsAnchor.target(.text, geometry: geometry, style: nil), .drop)
    }

    func testAFontOrAColourAloneIsEnough() {
        // AppKit tells the font and no colour, Chromium the colour and no typeface, an empty field neither.
        let geometry = CapsulePlacement.Geometry(element: field, caret: caret)
        for style in [CaretStyle(fontName: "Menlo-Regular", fontSize: 11), CaretStyle(fontSize: 15, color: SIMD3(1, 1, 1)), CaretStyle()] {
            XCTAssertEqual(LiveWordsAnchor.target(.text, geometry: geometry, style: style), .caret(caret, width: 399))
        }
    }

    func testTextAfterTheCaretOnItsLineFallsBack() {
        let geometry = CapsulePlacement.Geometry(element: field, caret: caret)
        XCTAssertEqual(LiveWordsAnchor.target(.text, geometry: geometry, style: CaretStyle(color: SIMD3(0, 0, 0), followed: true)), .drop)
    }

    func testAGoodCaretGivesTheRoomToTheEdge() {
        XCTAssertEqual(target(caret: caret), .caret(caret, width: 399))
        let geometry = CapsulePlacement.Geometry(element: nil, window: CGRect(x: 0, y: 0, width: 1_000, height: 600), caret: caret)
        XCTAssertEqual(LiveWordsAnchor.target(.text, geometry: geometry, style: style), .caret(caret, width: 699))
    }
}
