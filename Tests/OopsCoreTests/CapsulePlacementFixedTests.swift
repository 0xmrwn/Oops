import CoreGraphics
import XCTest
@testable import OopsCore

/// The dictation drop fixed to the top or bottom of a screen. AX points, top-left origin.
final class CapsulePlacementFixedTests: XCTestCase {
    private let envelope = CGSize(width: 252, height: 50)
    /// A notched 1512×982 built-in display: a 38 pt menu bar and notch area, and a 70 pt Dock.
    private let builtIn = CapsulePlacement.Screen(visible: CGRect(x: 0, y: 38, width: 1512, height: 874),
                                                  full: CGRect(x: 0, y: 0, width: 1512, height: 982), safeAreaTop: 38)
    /// An external 2560×1440 display above and to the right of it, with a 25 pt menu bar and no Dock.
    private let external = CapsulePlacement.Screen(visible: CGRect(x: 1512, y: -73, width: 2560, height: 1415),
                                                   full: CGRect(x: 1512, y: -98, width: 2560, height: 1440))
    private let onExternal = CGRect(x: 2000, y: 300, width: 800, height: 600)

    private func fixed(_ position: DictationDropPosition, on screens: [CapsulePlacement.Screen], anchor: CGRect? = nil) -> CGRect {
        CapsulePlacement.fixed(position, envelope: envelope, screens: screens, anchor: anchor).envelope
    }

    func testFixedTopOnANotchedDisplayClearsTheNotchAndIsCentred() {
        let frame = fixed(.top, on: [builtIn])
        XCTAssertEqual(frame, CGRect(x: 630, y: 50, width: 252, height: 50))
        XCTAssertTrue(builtIn.visible.contains(frame))
        XCTAssertEqual(frame.midX, builtIn.visible.midX)
    }

    func testFixedBottomOnANotchedDisplayStaysAboveTheDock() {
        let frame = fixed(.bottom, on: [builtIn])
        XCTAssertEqual(frame, CGRect(x: 630, y: 850, width: 252, height: 50))
        XCTAssertTrue(builtIn.visible.contains(frame))
        XCTAssertEqual(frame.midX, builtIn.visible.midX)
    }

    func testFixedTopLeavesRoomForANotchTallerThanTheMenuBar() {
        let tall = CapsulePlacement.Screen(visible: builtIn.visible, full: builtIn.full, safeAreaTop: 50)
        XCTAssertEqual(fixed(.top, on: [tall]).minY, 62)
    }

    func testFixedPlacementOnAnExternalDisplayWithANonZeroOrigin() {
        for position in [DictationDropPosition.top, .bottom] {
            let frame = fixed(position, on: [builtIn, external], anchor: onExternal)
            XCTAssertTrue(external.visible.contains(frame))
            XCTAssertEqual(frame.midX, external.visible.midX)
        }
        XCTAssertEqual(fixed(.top, on: [builtIn, external], anchor: onExternal).minY, -61)
        XCTAssertEqual(fixed(.bottom, on: [builtIn, external], anchor: onExternal).maxY, 1330)
    }

    func testFixedPlacementWithoutAnAnchorUsesTheFirstScreen() {
        XCTAssertTrue(external.visible.contains(fixed(.bottom, on: [external, builtIn])))
    }

    func testTheTopHugsTheTopEdgeAndTheBottomTheBottom() {
        // However tall the envelope (a dictation drop with room for its live words), the drop stays by its edge.
        let tall = CGSize(width: 252, height: 78)
        XCTAssertEqual(CapsulePlacement.fixed(.top, envelope: tall, screens: [builtIn]).corner, .top)
        XCTAssertEqual(CapsulePlacement.fixed(.bottom, envelope: tall, screens: [builtIn]).corner, .bottom)
    }

    func testAnchoredWithoutAnAnchorFallsBackToTheBottom() {
        XCTAssertEqual(DictationDropPosition.anchored.resolved(hasAnchor: false), .bottom)
        XCTAssertEqual(DictationDropPosition.anchored.resolved(hasAnchor: true), .anchored)
        XCTAssertEqual(DictationDropPosition.top.resolved(hasAnchor: false), .top)
    }
}
