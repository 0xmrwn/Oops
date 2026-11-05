import CoreGraphics
import XCTest
@testable import OopsCore

/// Geometry from the placement probe on a 1470×956 display.
final class CapsulePlacementTests: XCTestCase {
    private let screens = [CGRect(x: 0, y: 33, width: 1470, height: 923)]
    private let envelope = CGSize(width: 252, height: 50)
    private let window = CGRect(x: 0, y: 33, width: 1470, height: 923)
    private func groups(_ frames: [CGRect]) -> [CapsulePlacement.Ancestor] { frames.map { .init(role: "AXGroup", frame: $0) } }
    private func place(_ geometry: CapsulePlacement.Geometry?) -> CapsulePlacement.Placement {
        CapsulePlacement.place(geometry, envelope: envelope, screens: screens)
    }

    func testClaudeAnchorsAboveItsRoundedComposerIncludingTheToolbar() {
        let geometry = CapsulePlacement.Geometry(element: CGRect(x: 427, y: 884, width: 644, height: 21), ancestors: groups([
            CGRect(x: 427, y: 880, width: 644, height: 28), CGRect(x: 427, y: 880, width: 644, height: 28),
            CGRect(x: 391, y: 880, width: 752, height: 28), CGRect(x: 383, y: 872, width: 768, height: 44),
            CGRect(x: 383, y: 872, width: 768, height: 76)]), window: window,
            caret: CGRect(x: 0, y: 956, width: 0, height: 0), previousCharacter: CGRect(x: 0, y: 956, width: 0, height: 0))
        XCTAssertEqual(CapsulePlacement.composerBox(geometry), CGRect(x: 383, y: 872, width: 768, height: 76))
        let placement = place(geometry)
        XCTAssertEqual(placement.strategy, .composer); XCTAssertEqual(placement.corner, .bottomTrailing)
        XCTAssertEqual(placement.envelope, CGRect(x: 899, y: 814, width: 252, height: 50))
    }

    func testCodexStopsBeforeTheFullWidthBottomBar() {
        let geometry = CapsulePlacement.Geometry(element: CGRect(x: 249, y: 851, width: 712, height: 44), ancestors: groups([
            CGRect(x: 237, y: 837, width: 736, height: 98), CGRect(x: 237, y: 837, width: 736, height: 98),
            CGRect(x: 221, y: 837, width: 768, height: 98), CGRect(x: 52, y: 837, width: 1259, height: 114)]), window: window)
        XCTAssertEqual(CapsulePlacement.composerBox(geometry), CGRect(x: 221, y: 837, width: 768, height: 98))
        XCTAssertEqual(place(geometry).envelope, CGRect(x: 737, y: 779, width: 252, height: 50))
    }

    func testTeamsAnchorsToItsBorderedFieldNotThePaddedContainer() {
        let geometry = CapsulePlacement.Geometry(element: CGRect(x: 474, y: 848, width: 910, height: 38), ancestors: groups([
            CGRect(x: 474, y: 848, width: 910, height: 38), CGRect(x: 473, y: 847, width: 912, height: 42),
            CGRect(x: 401, y: 821, width: 1056, height: 129), CGRect(x: 387, y: 142, width: 1083, height: 814)]), window: window)
        // The visible box is 474–1383 × 848–929: its top-right corner is the bordered field's.
        XCTAssertEqual(CapsulePlacement.composerBox(geometry), CGRect(x: 473, y: 847, width: 912, height: 42))
        XCTAssertEqual(place(geometry).envelope, CGRect(x: 1133, y: 789, width: 252, height: 50))
    }

    func testMailBodyIsTooTallSoTheTextMarkerCaretAnchors() {
        let body = CGRect(x: 592, y: 329, width: 836, height: 523)
        let geometry = CapsulePlacement.Geometry(element: body, ancestors: [
            .init(role: "AXScrollArea", frame: body), .init(role: "AXGroup", frame: body), .init(role: "AXGroup", frame: body),
            .init(role: "AXWindow", frame: CGRect(x: 592, y: 73, width: 836, height: 779))],
            window: CGRect(x: 592, y: 73, width: 836, height: 779), caret: CGRect(x: 690, y: 355, width: 2, height: 14))
        let placement = place(geometry)
        XCTAssertEqual(placement.strategy, .caret); XCTAssertEqual(placement.corner, .topLeading)
        XCTAssertEqual(placement.envelope, CGRect(x: 678, y: 377, width: 252, height: 50))
    }

    func testAppKitLineEndCaretUsesThePreviousCharactersLine() {
        let scroll = CGRect(x: 441, y: 315.5, width: 588, height: 226.5)
        let geometry = CapsulePlacement.Geometry(element: scroll, ancestors: [
            .init(role: "AXScrollArea", frame: scroll), .init(role: "AXGroup", frame: CGRect(x: 415, y: 134, width: 640, height: 520))],
            window: CGRect(x: 415, y: 134, width: 640, height: 520),
            caret: CGRect(x: 584.3, y: 353.5, width: 0, height: 22), previousCharacter: CGRect(x: 575.7, y: 375.4, width: 8.6, height: 22))
        XCTAssertEqual(CapsulePlacement.composerBox(geometry), scroll)
        let placement = place(geometry)
        XCTAssertEqual(placement.strategy, .caret)
        XCTAssertEqual(placement.envelope.minX, 572.3, accuracy: 0.01)
        XCTAssertEqual(placement.envelope.minY, 405.4, accuracy: 0.01)
    }

    func testCaretNearTheScreenBottomGoesAboveTheLine() {
        let body = CGRect(x: 100, y: 500, width: 800, height: 440)
        let geometry = CapsulePlacement.Geometry(element: body, window: window, caret: CGRect(x: 300, y: 920, width: 2, height: 16))
        let placement = place(geometry)
        XCTAssertEqual(placement.strategy, .caretAbove); XCTAssertEqual(placement.corner, .bottomLeading)
        XCTAssertEqual(placement.envelope.maxY, 912)
    }

    func testChromiumPlaceholderCaretInATallComposerFallsBackToTheEdge() {
        let geometry = CapsulePlacement.Geometry(element: CGRect(x: 427, y: 500, width: 644, height: 300), window: window,
                                                 caret: CGRect(x: 0, y: 33, width: 0, height: 0))
        XCTAssertEqual(place(geometry).strategy, .composer)
    }

    func testComposerAtTheTopGoesBelowIt() {
        let geometry = CapsulePlacement.Geometry(element: CGRect(x: 300, y: 60, width: 600, height: 40), window: window)
        let placement = place(geometry)
        XCTAssertEqual(placement.strategy, .composerBelow); XCTAssertEqual(placement.corner, .topTrailing)
        XCTAssertEqual(placement.envelope.minY, 108)
    }

    func testNoComposerUsesTheWindowThenTheScreen() {
        let onlyWindow = CapsulePlacement.Geometry(element: nil, window: CGRect(x: 100, y: 100, width: 800, height: 600))
        XCTAssertEqual(place(onlyWindow).strategy, .window)
        XCTAssertEqual(place(onlyWindow).envelope, CGRect(x: 374, y: 626, width: 252, height: 50))
        let nothing = place(nil)
        XCTAssertEqual(nothing.strategy, .screen); XCTAssertEqual(nothing.corner, .bottom)
        XCTAssertEqual(nothing.envelope, CGRect(x: 609, y: 816, width: 252, height: 50))
    }

    func testEnvelopeStaysOnTheScreenTheComposerIsOn() {
        let second = CGRect(x: 1470, y: 0, width: 1920, height: 1080)
        let geometry = CapsulePlacement.Geometry(element: CGRect(x: 3340, y: 900, width: 80, height: 30))
        let placement = CapsulePlacement.place(geometry, envelope: envelope, screens: screens + [second])
        XCTAssertTrue(second.insetBy(dx: 8, dy: 8).contains(placement.envelope))
        XCTAssertEqual(placement.envelope.maxX, second.maxX - 8)
    }

    // Composer lab in Chrome (fixtures/composer-lab), window 1100×760 at (185, 95).
    private let labWindow = CGRect(x: 185, y: 95, width: 1100, height: 760)
    private let page = CGRect(x: 185, y: 127, width: 1100, height: 728)

    func testDocumentEditorNeverClimbsToThePage() {
        let body = CGRect(x: 238, y: 192, width: 994, height: 618)
        let geometry = CapsulePlacement.Geometry(element: body, ancestors: [
            .init(role: "AXGroup", frame: page), .init(role: "AXWebArea", frame: page), .init(role: "AXScrollArea", frame: page)],
            window: labWindow)
        XCTAssertEqual(CapsulePlacement.composerBox(geometry), body)
        XCTAssertEqual(place(geometry).envelope.minY, 134)
    }

    func testFieldAtTheTopOfTheWindowGoesBelowRatherThanOverTheTitleBar() {
        let geometry = CapsulePlacement.Geometry(element: CGRect(x: 222, y: 180, width: 1026, height: 24), ancestors: [
            .init(role: "AXGroup", frame: CGRect(x: 209, y: 171, width: 1052, height: 42)), .init(role: "AXGroup", frame: page)],
            window: labWindow)
        let placement = place(geometry)
        XCTAssertEqual(placement.strategy, .composerBelow)
        XCTAssertEqual(placement.envelope.minY, 221)
    }

    func testSidePanelComposerAnchorsAboveItselfAtTheBottomOfThePanel() {
        let geometry = CapsulePlacement.Geometry(element: CGRect(x: 1011, y: 793, width: 249, height: 43), ancestors: [
            .init(role: "AXGroup", frame: page), .init(role: "AXWebArea", frame: page)], window: labWindow,
            caret: CGRect(x: 0, y: 956, width: 0, height: 0), previousCharacter: CGRect(x: 0, y: 956, width: 0, height: 0))
        let placement = place(geometry)
        XCTAssertEqual(placement.strategy, .composer); XCTAssertEqual(placement.corner, .bottomTrailing)
        XCTAssertEqual(placement.envelope, CGRect(x: 1008, y: 735, width: 252, height: 50))
    }

    func testModalFieldAnchorsAboveItsBoxInsideTheDialog() {
        let geometry = CapsulePlacement.Geometry(element: CGRect(x: 507, y: 494, width: 456, height: 22), ancestors: [
            .init(role: "AXGroup", frame: CGRect(x: 494, y: 483, width: 482, height: 40)), .init(role: "AXGroup", frame: page),
            .init(role: "AXWebArea", frame: page)], window: labWindow,
            caret: CGRect(x: 0, y: 956, width: 0, height: 0), previousCharacter: CGRect(x: 0, y: 956, width: 0, height: 0))
        XCTAssertEqual(CapsulePlacement.composerBox(geometry), CGRect(x: 494, y: 483, width: 482, height: 40))
        XCTAssertEqual(place(geometry).envelope, CGRect(x: 724, y: 425, width: 252, height: 50))
    }

    func testHiddenInputProxyAnchorsToTheEditorAroundIt() {
        // Monaco's 1×1 textarea at the caret, inside the editor's box.
        let geometry = CapsulePlacement.Geometry(element: CGRect(x: 640, y: 760, width: 1, height: 1), ancestors: [
            .init(role: "AXGroup", frame: CGRect(x: 494, y: 740, width: 482, height: 60)), .init(role: "AXGroup", frame: page),
            .init(role: "AXWebArea", frame: page)], window: labWindow)
        XCTAssertEqual(CapsulePlacement.composerBox(geometry), CGRect(x: 494, y: 740, width: 482, height: 60))
        XCTAssertEqual(place(geometry).strategy, .composer)
        XCTAssertNil(CapsulePlacement.composerBox(.init(element: CGRect(x: 640, y: 760, width: 1, height: 1), ancestors: [
            .init(role: "AXWebArea", frame: page)], window: labWindow)))
    }

    // Native lab (fixtures/native-lab), window 1100×792 at (185, 95).
    private let nativeWindow = CGRect(x: 185, y: 95, width: 1100, height: 792)
    private let nativeScroll = CGRect(x: 185, y: 127, width: 1100, height: 760)

    func testGrownChatComposerAnchorsToItsEdgeNotBelowTheCaretOverItsToolbar() {
        let geometry = CapsulePlacement.Geometry(element: CGRect(x: 214, y: 702, width: 1042, height: 132), ancestors: [
            .init(role: "AXGroup", frame: CGRect(x: 201, y: 691, width: 1068, height: 181)), .init(role: "AXWebArea", frame: nativeScroll)],
            window: nativeWindow, caret: CGRect(x: 525, y: 808, width: 2, height: 22))
        XCTAssertEqual(place(geometry).strategy, .composer)
    }

    func testScrolledAwayCaretIsIgnoredAndTheDocumentUsesTheWindow() {
        let geometry = CapsulePlacement.Geometry(element: CGRect(x: 185, y: 127, width: 1100, height: 1786), ancestors: [
            .init(role: "AXScrollArea", frame: nativeScroll), .init(role: "AXWindow", frame: nativeWindow)],
            window: nativeWindow, caret: CGRect(x: 214, y: 1857, width: 0, height: 18),
            previousCharacter: CGRect(x: 226.9, y: 1857, width: 1029.1, height: 18))
        XCTAssertEqual(CapsulePlacement.composerBox(geometry), nativeScroll)
        let placement = place(geometry)
        XCTAssertEqual(placement.strategy, .window)
        XCTAssertTrue(nativeWindow.contains(placement.envelope))
    }

    func testRightToLeftCaretNearTheRightEdgeGrowsLeftward() {
        let geometry = CapsulePlacement.Geometry(element: CGRect(x: 185, y: 127, width: 1100, height: 754), ancestors: [
            .init(role: "AXScrollArea", frame: nativeScroll)], window: nativeWindow,
            caret: CGRect(x: 1202.3, y: 147, width: 0, height: 18), previousCharacter: CGRect(x: 1202.3, y: 165, width: 10.1, height: 18))
        let placement = place(geometry)
        XCTAssertEqual(placement.strategy, .caret); XCTAssertEqual(placement.corner, .topTrailing)
        XCTAssertLessThanOrEqual(placement.envelope.maxX, nativeWindow.maxX)
    }

    func testElementLaidOutWiderThanItsWindowIsClipped() {
        let geometry = CapsulePlacement.Geometry(element: CGRect(x: 211, y: 807, width: 2148, height: 58), ancestors: [
            .init(role: "AXScrollArea", frame: CGRect(x: 211, y: 807, width: 2148, height: 54)),
            .init(role: "AXGroup", frame: CGRect(x: 201, y: 797, width: 2168, height: 74)), .init(role: "AXWindow", frame: nativeWindow)],
            window: nativeWindow)
        XCTAssertEqual(CapsulePlacement.composerBox(geometry)?.maxX, nativeWindow.maxX)
        XCTAssertEqual(place(geometry).envelope.maxX, nativeWindow.maxX)
    }

    func testOffWindowElementIsNotAnAnchor() {
        let geometry = CapsulePlacement.Geometry(element: CGRect(x: 2000, y: 2000, width: 300, height: 30),
                                                 window: CGRect(x: 0, y: 33, width: 800, height: 600))
        XCTAssertNil(CapsulePlacement.composerBox(geometry))
        XCTAssertEqual(place(geometry).strategy, .window)
    }
}
