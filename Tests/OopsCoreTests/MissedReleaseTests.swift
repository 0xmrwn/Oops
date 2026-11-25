import XCTest
@testable import OopsCore

final class MissedReleaseTests: XCTestCase {
    private typealias Watch = MissedRelease<Int>

    func testAKeyStillDownInfersNothing() {
        var watch = Watch()
        for time in 0 ..< 100 { XCTAssertNil(watch.sample(session: true, hardware: true, at: time)) }
    }

    func testAKeyUpForOneSampleWaitsForTheRealRelease() {
        var watch = Watch()
        XCTAssertNil(watch.sample(session: true, hardware: true, at: 0))
        XCTAssertNil(watch.sample(session: false, hardware: false, at: 1))
        XCTAssertEqual(watch.observedUp, 1)
    }

    func testAKeyThatStaysUpIsReleasedWhenItFirstReadUp() {
        var watch = Watch()
        _ = watch.sample(session: true, hardware: true, at: 0)
        XCTAssertNil(watch.sample(session: false, hardware: false, at: 7))
        XCTAssertEqual(watch.sample(session: false, hardware: false, at: 8), 7)
    }

    func testAKeyDownAgainStartsOver() {
        var watch = Watch()
        XCTAssertNil(watch.sample(session: false, hardware: false, at: 1))
        XCTAssertNil(watch.sample(session: true, hardware: true, at: 2))
        XCTAssertNil(watch.observedUp)
        XCTAssertNil(watch.sample(session: false, hardware: false, at: 3))
        XCTAssertEqual(watch.sample(session: false, hardware: false, at: 4), 3)
    }

    /// A remapper can leave the session's state down: the keyboard reading up long enough settles it.
    func testASessionStuckDownIsReleasedByTheKeyboard() {
        var watch = Watch()
        XCTAssertNil(watch.sample(session: true, hardware: true, at: 0))
        XCTAssertNil(watch.sample(session: true, hardware: false, at: 1))
        XCTAssertNil(watch.sample(session: true, hardware: false, at: 2))
        XCTAssertEqual(watch.sample(session: true, hardware: false, at: 3), 1)
    }

    /// A key only another app posts reads down in the session alone: one keyboard glimpse doesn't cut its hold.
    func testAKeyboardGlimpseAloneIsNotARelease() {
        var watch = Watch()
        XCTAssertNil(watch.sample(session: true, hardware: false, at: 0))
        XCTAssertNil(watch.sample(session: true, hardware: true, at: 1))
        XCTAssertNil(watch.sample(session: true, hardware: false, at: 2))
        XCTAssertNil(watch.sample(session: true, hardware: false, at: 3))
    }

    /// The bound: a key both states read down is never released, and the watch ends at its limit.
    func testAHoldIsNeverCutAndTheWatchEnds() {
        var watch = Watch()
        let samples = Int(Watch.limit / Watch.interval)
        for time in 0 ..< samples { XCTAssertNil(watch.sample(session: true, hardware: true, at: time)) }
        XCTAssertTrue(watch.isExpired)
        XCTAssertNil(watch.sample(session: false, hardware: false, at: samples))
        XCTAssertGreaterThanOrEqual(Watch.limit, .seconds(30 * 60))
    }

    func testTheWaitIsBounded() {
        XCTAssertLessThanOrEqual(Watch.interval * Watch.confirmations, .milliseconds(150))
        XCTAssertLessThanOrEqual(Watch.interval * Watch.staleAfter, .milliseconds(150))
    }
}

final class HotkeyHoldsTests: XCTestCase {
    private enum Action: Hashable { case fix, dictate }
    private typealias Holds = HotkeyHolds<Action, Int>
    private let up = (session: false, hardware: false), down = (session: true, hardware: true)

    private func told(_ list: [(event: Holds.Event, at: Int)]) -> [String] {
        list.map { "\($0.event.phase == .pressed ? "down" : "up")@\($0.at)" }
    }

    /// A double tap whose first release went missing: the second press comes between the up and its
    /// confirmation. The first release is told, at the up, before the second press, so both taps count.
    func testAPressAfterAnUpTellsTheMissingReleaseFirst() {
        var holds = Holds([.fix, .dictate])
        XCTAssertEqual(told(holds.route(identity: 2, pressed: true, at: 0)), ["down@0"])
        XCTAssertTrue(holds.sample(at: 5) { _ in self.up }.released.isEmpty)
        XCTAssertEqual(told(holds.route(identity: 2, pressed: true, at: 8)), ["up@5", "down@8"])
        // The second hold is watched afresh: its key going up is dated from this hold alone.
        XCTAssertTrue(holds.sample(at: 9) { _ in self.down }.released.isEmpty)
        XCTAssertTrue(holds.sample(at: 12) { _ in self.up }.released.isEmpty)
        XCTAssertEqual(told(holds.sample(at: 13) { _ in self.up }.released), ["up@12"])
    }

    /// A press with nothing seen up is a repeat, as before.
    func testARepeatedPressIsStillDropped() {
        var holds = Holds([.fix, .dictate])
        _ = holds.route(identity: 2, pressed: true, at: 0)
        _ = holds.sample(at: 5) { _ in self.down }
        XCTAssertTrue(holds.route(identity: 2, pressed: true, at: 6).isEmpty)
    }

    /// An up seen in one hold never dates the release of the next one.
    func testEachEdgeStartsTheWatchOver() {
        var holds = Holds([.fix, .dictate])
        _ = holds.route(identity: 2, pressed: true, at: 0)
        _ = holds.sample(at: 5) { _ in self.up }
        XCTAssertEqual(told(holds.route(identity: 2, pressed: false, at: 6)), ["up@6"])
        XCTAssertEqual(told(holds.route(identity: 2, pressed: true, at: 7)), ["down@7"])
        XCTAssertTrue(holds.sample(at: 20) { _ in self.up }.released.isEmpty)
        XCTAssertEqual(told(holds.sample(at: 21) { _ in self.up }.released), ["up@20"])
    }

    func testARealReleaseEndsTheWatch() {
        var holds = Holds([.fix, .dictate])
        _ = holds.route(identity: 1, pressed: true, at: 0)
        XCTAssertTrue(holds.isWatching)
        _ = holds.route(identity: 1, pressed: false, at: 3)
        XCTAssertFalse(holds.isWatching)
        XCTAssertTrue(holds.sample(at: 4) { _ in self.up }.released.isEmpty)
    }

    func testAChordWithNoKeyIsNotSampled() {
        var holds = Holds([.fix, .dictate])
        _ = holds.route(identity: 1, pressed: true, at: 0)
        for time in 1 ... 5 { XCTAssertTrue(holds.sample(at: time) { _ in nil }.released.isEmpty) }
        XCTAssertEqual(holds.router.held, [.fix])
    }
}
