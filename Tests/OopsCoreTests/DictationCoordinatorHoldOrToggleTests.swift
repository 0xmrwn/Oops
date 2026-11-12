import XCTest
@testable import OopsCore

/// Hold-or-toggle and the two plain modes, driven through the real machine on a synthetic clock. Recording
/// starts on key-down in every mode; the tests pin how each mode ends it.
final class DictationCoordinatorHoldOrToggleTests: XCTestCase {
    /// A key held past the threshold is push-to-talk: the (deferred) release stops recording.
    func testHoldOrToggleLongHoldStopsOnRelease() {
        let mode = DictationCoordinator.Activation.holdOrToggle
        var state = DictationCoordinator()
        let t0 = ContinuousClock.now

        XCTAssertTrue(state.onInput(input(mode, true), now: t0).isStart)
        XCTAssertNil(state.onInput(input(mode, false), now: t0 + ms(800)))
        XCTAssertTrue(
            state.onGraceExpired().isStop, "an 800ms hold must stop when its release grace elapses")
        XCTAssertEqual(state.stage, .processing)
    }

    /// A tap keeps recording (locked on); the next press stops.
    func testHoldOrToggleTapLocksRecordingUntilNextPress() {
        let mode = DictationCoordinator.Activation.holdOrToggle
        var state = DictationCoordinator()
        let t0 = ContinuousClock.now

        XCTAssertTrue(state.onInput(input(mode, true), now: t0).isStart)
        XCTAssertNil(state.onInput(input(mode, false), now: t0 + ms(120)))
        XCTAssertNil(state.onGraceExpired(), "a 120ms tap must not stop recording")
        XCTAssertEqual(state.stage, .recording(binding))
        XCTAssertTrue(state.isLocked)

        // Seconds later the user presses again to finish.
        XCTAssertTrue(state.onInput(input(mode, true), now: t0 + ms(5000)).isStop)
        XCTAssertEqual(state.stage, .processing)
        // The release of that stopping press lands in the busy window and is ignored, so nothing is
        // remembered for the drain.
        XCTAssertNil(state.onInput(input(mode, false), now: t0 + ms(5080)))
        XCTAssertNil(state.onProcessingFinished())
        XCTAssertEqual(state.stage, .idle)
    }

    /// A locked session ignores stray releases: only a press ends it.
    func testHoldOrToggleLockedSessionIgnoresRelease() {
        let mode = DictationCoordinator.Activation.holdOrToggle
        var state = DictationCoordinator()
        let t0 = ContinuousClock.now

        _ = state.onInput(input(mode, true), now: t0)
        _ = state.onInput(input(mode, false), now: t0 + ms(100))
        XCTAssertNil(state.onGraceExpired())
        XCTAssertTrue(state.isLocked)

        XCTAssertNil(state.onInput(input(mode, false), now: t0 + ms(900)))
        XCTAssertNil(state.graceDeadline, "no release may be deferred once locked")
        XCTAssertEqual(state.stage, .recording(binding))
    }

    /// While the key is genuinely held, extra presses do not stop the recording (that is the release's job).
    func testHoldOrTogglePressWhileHeldIsIgnored() {
        let mode = DictationCoordinator.Activation.holdOrToggle
        var state = DictationCoordinator()
        let t0 = ContinuousClock.now

        _ = state.onInput(input(mode, true), now: t0)
        XCTAssertNil(state.onInput(input(mode, true), now: t0 + ms(400)))
        XCTAssertEqual(state.stage, .recording(binding))
        XCTAssertFalse(state.isLocked)
    }

    /// Under X11 auto-repeat the synthesized release/press pairs must not be misread as taps. The hold is
    /// measured from the original key-down to the genuine key-up.
    func testHoldOrToggleAutorepeatBurstIsOneLongHold() {
        let mode = DictationCoordinator.Activation.holdOrToggle
        var state = DictationCoordinator()
        let t0 = ContinuousClock.now
        var clock = t0

        XCTAssertTrue(state.onInput(input(mode, true), now: clock).isStart)
        // ~600ms of auto-repeat pairs a few ms apart.
        for _ in 0..<60 {
            clock += ms(5)
            XCTAssertNil(state.onInput(input(mode, false), now: clock))
            clock += ms(5)
            XCTAssertNil(state.onInput(input(mode, true), now: clock))
            XCTAssertNil(
                state.graceDeadline, "auto-repeat press must cancel the deferred release")
        }
        XCTAssertFalse(state.isLocked, "no tap may be classified mid-burst")

        clock += ms(5)
        XCTAssertNil(state.onInput(input(mode, false), now: clock))
        XCTAssertTrue(
            state.onGraceExpired().isStop,
            "the genuine release after a ~600ms hold must stop recording")
    }

    /// A press remembered during the busy window is measured from the real key-down, so a hold that
    /// straddles the drain still counts as a hold when it is released shortly after recording actually
    /// starts.
    func testHoldOrToggleRememberedPressMeasuresHoldFromRealKeyDown() {
        let mode = DictationCoordinator.Activation.holdOrToggle
        var state = DictationCoordinator()
        let t0 = ContinuousClock.now

        // Previous session: hold, release, stop -> processing.
        _ = state.onInput(input(mode, true), now: t0)
        _ = state.onInput(input(mode, false), now: t0 + ms(800))
        XCTAssertTrue(state.onGraceExpired().isStop)

        // Pressed again while busy; still held when the pipeline drains 700ms later.
        XCTAssertNil(state.onInput(input(mode, true), now: t0 + ms(1000)))
        XCTAssertTrue(state.onProcessingFinished().isStart)
        // Released 100ms after recording began, but 800ms after key-down.
        XCTAssertNil(state.onInput(input(mode, false), now: t0 + ms(1800)))
        XCTAssertTrue(state.onGraceExpired().isStop, "held 800ms overall: must stop, not lock")
    }

    /// Toggle: releases never stop, the next press does. (Toggle is the combined machine with the session
    /// locked from the start.)
    func testToggleModeIgnoresReleaseAndStopsOnNextPress() {
        let mode = DictationCoordinator.Activation.toggle
        var state = DictationCoordinator()
        let t0 = ContinuousClock.now

        XCTAssertTrue(state.onInput(input(mode, true), now: t0).isStart)
        XCTAssertTrue(state.isLocked)
        XCTAssertNil(state.onInput(input(mode, false), now: t0 + ms(100)))
        XCTAssertNil(state.graceDeadline, "toggle never defers releases")
        XCTAssertNil(state.onInput(input(mode, false), now: t0 + ms(3000)))
        XCTAssertTrue(state.onInput(input(mode, true), now: t0 + ms(4000)).isStop)
    }

    /// Push-to-talk: even a very short press stops on release; there is no tap-to-lock in this mode (hold
    /// threshold of zero).
    func testPushToTalkShortPressStillStopsOnRelease() {
        let mode = DictationCoordinator.Activation.pushToTalk
        var state = DictationCoordinator()
        let t0 = ContinuousClock.now

        XCTAssertTrue(state.onInput(input(mode, true), now: t0).isStart)
        XCTAssertNil(state.onInput(input(mode, false), now: t0 + ms(40)))
        XCTAssertTrue(state.onGraceExpired().isStop)
    }

    /// Cancel (Escape) during a locked hold-or-toggle session resets cleanly so the next press starts a
    /// fresh recording rather than stopping a dead one.
    func testHoldOrToggleCancelClearsLockedSession() {
        let mode = DictationCoordinator.Activation.holdOrToggle
        var state = DictationCoordinator()
        let t0 = ContinuousClock.now

        _ = state.onInput(input(mode, true), now: t0)
        _ = state.onInput(input(mode, false), now: t0 + ms(100))
        XCTAssertNil(state.onGraceExpired())
        XCTAssertTrue(state.isLocked)

        state.onCancel(recordingWasActive: true)
        XCTAssertEqual(state.stage, .idle)
        XCTAssertFalse(state.isLocked)
        XCTAssertTrue(state.onInput(input(mode, true), now: t0 + ms(2000)).isStart)
    }

    /// Switching to toggle while an unlocked hold recording is running must not strand it: in toggle mode
    /// a press always stops.
    func testTogglePressStopsRecordingStartedAsHold() {
        var state = DictationCoordinator()
        let t0 = ContinuousClock.now

        _ = state.onInput(input(.holdOrToggle, true), now: t0)
        XCTAssertFalse(state.isLocked)
        XCTAssertTrue(state.onInput(input(.toggle, true), now: t0 + ms(2000)).isStop)
    }
}
