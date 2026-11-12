import XCTest
@testable import OopsCore

/// Hold-versus-tap classification while the previous transcription is busy.
final class DictationCoordinatorBusyTests: XCTestCase {
    func testHoldOrToggleTapDuringProcessingQueuesLockedStart() {
        let mode = DictationCoordinator.Activation.holdOrToggle
        var state = DictationCoordinator()
        let t0 = ContinuousClock.now
        holdOrToggleIntoProcessing(&state, t0)

        XCTAssertNil(state.onInput(input(mode, true), now: t0 + ms(1000)))
        XCTAssertNil(state.onInput(input(mode, false), now: t0 + ms(1100)))
        XCTAssertNil(state.onGraceExpired())
        XCTAssertTrue(state.isLocked, "a busy tap should queue a locked start")
        XCTAssertTrue(state.onProcessingFinished().isStart)
        XCTAssertTrue(state.isLocked)
    }

    func testHoldOrToggleCompletedHoldDuringProcessingNetsNoop() {
        let mode = DictationCoordinator.Activation.holdOrToggle
        var state = DictationCoordinator()
        let t0 = ContinuousClock.now
        holdOrToggleIntoProcessing(&state, t0)

        XCTAssertNil(state.onInput(input(mode, true), now: t0 + ms(1000)))
        XCTAssertNil(state.onInput(input(mode, false), now: t0 + ms(1600)))
        XCTAssertNil(state.onGraceExpired())
        XCTAssertFalse(state.isLocked)

        XCTAssertNil(
            state.onProcessingFinished(),
            "a 600ms hold that ended before the drain has nothing left to start")
        XCTAssertEqual(state.stage, .idle)
    }

    func testHoldOrToggleTwoTapsDuringProcessingNetNoop() {
        let mode = DictationCoordinator.Activation.holdOrToggle
        var state = DictationCoordinator()
        let t0 = ContinuousClock.now
        holdOrToggleIntoProcessing(&state, t0)

        XCTAssertNil(state.onInput(input(mode, true), now: t0 + ms(1000)))
        XCTAssertNil(state.onInput(input(mode, false), now: t0 + ms(1100)))
        XCTAssertNil(state.onGraceExpired())
        XCTAssertTrue(state.isLocked)

        XCTAssertNil(state.onInput(input(mode, true), now: t0 + ms(1500)))
        XCTAssertFalse(state.isLocked, "the second tap's press forgets the queued tap")
        XCTAssertNil(state.onInput(input(mode, false), now: t0 + ms(1600)))
        XCTAssertNil(state.graceDeadline)

        XCTAssertNil(state.onProcessingFinished())
        XCTAssertEqual(state.stage, .idle)
    }

    func testPttTapInsideBusyWindowNetsNoop() {
        var state = DictationCoordinator()
        let t0 = ContinuousClock.now
        holdOrToggleIntoProcessing(&state, t0)

        XCTAssertNil(state.onInput(pttInput(true), now: t0 + ms(1000)))
        XCTAssertNil(state.onInput(pttInput(false), now: t0 + ms(1040)))
        XCTAssertNil(state.onGraceExpired())
        XCTAssertNil(state.onProcessingFinished())
    }

    /// The pipeline drains inside the 50ms grace of a busy tap: recording starts first (unlocked, from the
    /// real key-down), and the grace then resolves against the live recording, locking it as the tap it was.
    func testHoldOrToggleDrainInsideBusyReleaseGraceStillClassifiesTap() {
        let mode = DictationCoordinator.Activation.holdOrToggle
        var state = DictationCoordinator()
        let t0 = ContinuousClock.now
        holdOrToggleIntoProcessing(&state, t0)

        XCTAssertNil(state.onInput(input(mode, true), now: t0 + ms(1000)))
        XCTAssertNil(state.onInput(input(mode, false), now: t0 + ms(1100)))
        XCTAssertTrue(state.onProcessingFinished().isStart)
        XCTAssertFalse(state.isLocked)

        XCTAssertNil(state.onGraceExpired())
        XCTAssertTrue(state.isLocked, "the deferred 100ms release is a tap")
    }

    /// X11 auto-repeat while busy, key still held at the drain: recording starts measured from the first
    /// press, not from the last synthesized press before the drain. Released 400ms after the real key-down
    /// but only ~100ms after the drain: a hold, so it must stop rather than lock.
    func testHoldOrToggleAutorepeatBurstStraddlingDrainMeasuresFromFirstPress() {
        let mode = DictationCoordinator.Activation.holdOrToggle
        var state = DictationCoordinator()
        let t0 = ContinuousClock.now
        holdOrToggleIntoProcessing(&state, t0)

        var clock = t0 + ms(1000)
        XCTAssertNil(state.onInput(input(mode, true), now: clock))
        for _ in 0..<30 {
            clock += ms(5)
            XCTAssertNil(state.onInput(input(mode, false), now: clock))
            clock += ms(5)
            XCTAssertNil(state.onInput(input(mode, true), now: clock))
            XCTAssertNil(state.graceDeadline)
        }

        // Drain at ~t0 + 1300ms with the key still down.
        XCTAssertTrue(state.onProcessingFinished().isStart)
        XCTAssertFalse(state.isLocked)

        for _ in 0..<10 {
            clock += ms(5)
            XCTAssertNil(state.onInput(input(mode, false), now: clock))
            clock += ms(5)
            XCTAssertNil(state.onInput(input(mode, true), now: clock))
        }
        XCTAssertEqual(clock, t0 + ms(1400))
        XCTAssertNil(state.onInput(input(mode, false), now: clock))
        XCTAssertTrue(
            state.onGraceExpired().isStop, "held 400ms since the real key-down: must stop, not lock")
        XCTAssertEqual(state.stage, .processing)
    }
}
