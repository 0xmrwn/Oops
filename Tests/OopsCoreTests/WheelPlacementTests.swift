import CoreGraphics
import Testing
@testable import OopsCore

/// One 1440×900 screen at the origin, with a document filling most of a window.
struct WheelPlacementTests {
    private let screens = [CGRect(x: 0, y: 0, width: 1440, height: 900)]

    private func geometry(caret: CGRect) -> CapsulePlacement.Geometry {
        CapsulePlacement.Geometry(element: CGRect(x: 0, y: 100, width: 1440, height: 760), window: CGRect(x: 0, y: 60, width: 1440, height: 800), caret: caret)
    }

    @Test func `the wheel opens under the caret`() {
        let hub = WheelPlacement.hub(geometry(caret: CGRect(x: 400, y: 300, width: 2, height: 18)), screens: screens)
        #expect(hub == CGPoint(x: 411, y: 318 + 8 + 130))
    }

    @Test func `near the bottom it opens above the caret`() {
        let hub = WheelPlacement.hub(geometry(caret: CGRect(x: 400, y: 800, width: 2, height: 18)), screens: screens)
        #expect(hub.y + 130 <= 792)
    }

    @Test func `near the right edge the whole wheel stays on screen`() {
        let hub = WheelPlacement.hub(geometry(caret: CGRect(x: 1400, y: 300, width: 2, height: 18)), screens: screens)
        #expect(hub.x + 285 <= 1432)
    }

    @Test func `near the left edge too`() {
        let hub = WheelPlacement.hub(geometry(caret: CGRect(x: 20, y: 300, width: 2, height: 18)), screens: screens)
        #expect(hub.x - 285 >= 8)
    }

    @Test func `with no caret the wheel goes where Fix's drop would`() {
        let hub = WheelPlacement.hub(nil, screens: screens)
        #expect(hub.x == 720)
        #expect(hub.y - 130 >= 8 && hub.y + 130 <= 892)
    }
}
