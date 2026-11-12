import XCTest
@testable import OopsCore

final class HotkeyRouterTests: XCTestCase {
    private enum Action: Hashable { case fix, dictate }
    private typealias Event = HotkeyRouter<Action>.Event

    func testEachActionHasItsOwnIdentity() {
        let router = HotkeyRouter<Action>([.fix, .dictate])
        XCTAssertEqual(router.identity(of: .fix), 1)
        XCTAssertEqual(router.identity(of: .dictate), 2)
        XCTAssertEqual(router.action(for: 2), .dictate)
        XCTAssertNil(router.action(for: 0)); XCTAssertNil(router.action(for: 3))
    }

    func testTwoActionsEachDeliverTheirOwnPressAndRelease() {
        var router = HotkeyRouter<Action>([.fix, .dictate])
        XCTAssertEqual(router.route(identity: 2, pressed: true), Event(action: .dictate, phase: .pressed))
        // Fix pressed and let go while Dictate is still held.
        XCTAssertEqual(router.route(identity: 1, pressed: true), Event(action: .fix, phase: .pressed))
        XCTAssertEqual(router.held, [.fix, .dictate])
        XCTAssertEqual(router.route(identity: 1, pressed: false), Event(action: .fix, phase: .released))
        XCTAssertEqual(router.held, [.dictate])
        XCTAssertEqual(router.route(identity: 2, pressed: false), Event(action: .dictate, phase: .released))
        XCTAssertTrue(router.held.isEmpty)
    }

    func testAHeldChordRepeatingItsPressIsToldOnce() {
        var router = HotkeyRouter<Action>([.fix, .dictate])
        XCTAssertNotNil(router.route(identity: 1, pressed: true))
        XCTAssertNil(router.route(identity: 1, pressed: true))
        // The other action's press still gets through.
        XCTAssertEqual(router.route(identity: 2, pressed: true), Event(action: .dictate, phase: .pressed))
        XCTAssertNotNil(router.route(identity: 1, pressed: false))
        XCTAssertNotNil(router.route(identity: 1, pressed: true))
    }

    func testAReleaseWithNoPressAndAnUnknownIdentityAreDropped() {
        var router = HotkeyRouter<Action>([.fix, .dictate])
        XCTAssertNil(router.route(identity: 1, pressed: false))
        XCTAssertNil(router.route(identity: 9, pressed: true))
        XCTAssertTrue(router.held.isEmpty)
    }

    func testResetForgetsHeldChords() {
        var router = HotkeyRouter<Action>([.fix, .dictate])
        _ = router.route(identity: 1, pressed: true)
        router.reset()
        XCTAssertNil(router.route(identity: 1, pressed: false))
        XCTAssertEqual(router.route(identity: 1, pressed: true), Event(action: .fix, phase: .pressed))
    }

    func testResettingOwesEachHeldActionItsRelease() {
        var router = HotkeyRouter<Action>([.fix, .dictate])
        XCTAssertNotNil(router.route(identity: 2, pressed: true))
        XCTAssertEqual(router.reset(), [Event(action: .dictate, phase: .released)])
        XCTAssertTrue(router.held.isEmpty)
        // The release the old registration sends late is not told twice.
        XCTAssertNil(router.route(identity: 2, pressed: false))
        XCTAssertEqual(router.reset(), [])
    }
}
