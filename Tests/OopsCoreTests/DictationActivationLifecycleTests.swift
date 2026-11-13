import XCTest
@testable import OopsCore

/// A refused start, cancel in each state, and a mode changed while idle or mid-recording.
final class DictationActivationLifecycleTests: XCTestCase {
    func testFailedStartLeavesEveryModeIdle() {
        for mode in DictationMode.allCases {
            var drive = ActivationDriver(mode)
            XCTAssertEqual(drive.press(0), .start, "\(mode)")
            drive.activation.startResult(started: false)
            XCTAssertFalse(drive.isRecording, "\(mode)")
            XCTAssertNil(drive.release(100), "\(mode): the release of a refused press ends nothing")
            XCTAssertNil(drive.fire(), "\(mode)")
            XCTAssertEqual(drive.press(1000), .start, "\(mode): the next press starts afresh")
        }
    }

    func testFailedStartOfALockedDoubleTapLeavesIdle() {
        var drive = ActivationDriver(.holdOrDoubleTap)
        _ = drive.press(0)
        _ = drive.release(80)
        XCTAssertEqual(drive.press(180), .start)
        drive.activation.startResult(started: false)
        XCTAssertNil(drive.release(260))
        XCTAssertFalse(drive.isRecording)
        XCTAssertFalse(drive.isLocked)
    }

    func testSuccessfulStartChangesNothing() {
        for mode in DictationMode.allCases {
            var drive = ActivationDriver(mode)
            _ = drive.press(0)
            drive.activation.startResult(started: true)
            XCTAssertTrue(drive.isRecording, "\(mode)")
        }
    }

    func testCancelWhileIdleKeepsTheNextPressWorking() {
        for mode in DictationMode.allCases {
            var drive = ActivationDriver(mode)
            drive.activation.cancel(recordingWasActive: false)
            XCTAssertEqual(drive.press(0), .start, "\(mode)")
        }
    }

    func testCancelWhileHeldDropsTheRecordingAndItsRelease() {
        for mode in DictationMode.allCases {
            var drive = ActivationDriver(mode)
            _ = drive.press(0)
            drive.activation.cancel(recordingWasActive: true)
            XCTAssertFalse(drive.isRecording, "\(mode)")
            XCTAssertNil(drive.release(500), "\(mode)")
            XCTAssertNil(drive.fire(), "\(mode)")
            XCTAssertEqual(drive.press(1000), .start, "\(mode)")
        }
    }

    func testCancelInsideTheReleaseGraceDropsIt() {
        var drive = ActivationDriver(.holdOrTap)
        _ = drive.press(0)
        _ = drive.release(800)
        XCTAssertNotNil(drive.deadline)
        drive.activation.cancel(recordingWasActive: true)
        XCTAssertNil(drive.deadline)
        XCTAssertNil(drive.fire())
        XCTAssertFalse(drive.isRecording)
    }

    func testCancelWhileLockedLetsTheNextPressStart() {
        let latches: [(DictationMode, (inout ActivationDriver) -> Void)] = [
            (.holdOrTap, { _ = $0.press(0); _ = $0.release(100); _ = $0.fire() }),
            (.tapOnly, { _ = $0.press(0); _ = $0.release(100) }),
            (.holdOrDoubleTap, { _ = $0.press(0); _ = $0.release(80); _ = $0.press(180); _ = $0.release(260) }),
        ]
        for (mode, latch) in latches {
            var drive = ActivationDriver(mode)
            latch(&drive)
            XCTAssertTrue(drive.isLocked, "\(mode)")
            drive.activation.cancel(recordingWasActive: true)
            XCTAssertFalse(drive.isRecording, "\(mode)")
            XCTAssertFalse(drive.isLocked, "\(mode)")
            XCTAssertEqual(drive.press(2000), .start, "\(mode): a press after cancel starts, never stops")
        }
    }

    /// Cancel while transcribing lets the transcription finish but forgets a press remembered for it.
    func testCancelDuringProcessingForgetsTheRememberedPress() {
        let stops: [(DictationMode, (inout ActivationDriver) -> Void)] = [
            (.holdOrTap, { _ = $0.press(0); _ = $0.release(800); _ = $0.fire() }),
            (.holdOnly, { _ = $0.press(0); _ = $0.release(800); _ = $0.fire() }),
            (.tapOnly, { _ = $0.press(0); _ = $0.press(800) }),
            (.holdOrDoubleTap, { _ = $0.press(0); _ = $0.release(800) }),
        ]
        for (mode, stop) in stops {
            var drive = ActivationDriver(mode)
            stop(&drive)
            XCTAssertNil(drive.press(1500), "\(mode): remembered while busy")
            drive.activation.cancel(recordingWasActive: false)
            XCTAssertNil(drive.finished(), "\(mode): nothing starts at the drain")
            XCTAssertFalse(drive.isRecording, "\(mode)")
            XCTAssertNil(drive.release(1600), "\(mode)")
            XCTAssertEqual(drive.press(3000), .start, "\(mode)")
        }
    }

    func testCancelAfterADiscardClearsTheDoubleTapWindow() {
        var drive = ActivationDriver(.holdOrDoubleTap)
        _ = drive.press(0)
        XCTAssertEqual(drive.release(80), .discard)
        drive.activation.cancel(recordingWasActive: false)
        XCTAssertEqual(drive.press(180), .start)
        XCTAssertEqual(drive.release(260), .discard, "the cancelled tap no longer pairs")
    }

    // Mode changes.

    func testModeChangeWhileIdleAppliesToTheNextPress() {
        var drive = ActivationDriver(.holdOrTap)
        drive.activation.mode = .holdOnly
        XCTAssertEqual(drive.press(0), .start)
        XCTAssertNil(drive.release(100))
        XCTAssertEqual(drive.fire(), .stop, "hold only: a tap does not latch")

        drive.activation.mode = .holdOrDoubleTap
        XCTAssertNil(drive.finished())
        XCTAssertEqual(drive.press(1000), .start)
        XCTAssertEqual(drive.release(1100), .discard)
        XCTAssertNil(drive.deadline)

        drive.activation.mode = .tapOnly
        XCTAssertEqual(drive.press(1200), .start, "a tap-only press never pairs with the earlier tap")
        XCTAssertNil(drive.release(1250))
        XCTAssertTrue(drive.isLocked)
    }

    /// A hold-only recording keeps hold-only rules after a switch to tap only: its release still stops it.
    func testModeChangeMidHoldEndsByTheRulesItStartedUnder() {
        var drive = ActivationDriver(.holdOnly)
        XCTAssertEqual(drive.press(0), .start)
        drive.activation.mode = .tapOnly
        XCTAssertNil(drive.release(100))
        XCTAssertEqual(drive.fire(), .stop)
        XCTAssertNil(drive.finished())
        XCTAssertEqual(drive.press(1000), .start)
        XCTAssertNil(drive.release(1100))
        XCTAssertTrue(drive.isLocked, "tap only applies from the next press")
    }

    func testModeChangeWhileLatchedEndsOnTheNextPress() {
        var drive = ActivationDriver(.holdOrTap)
        _ = drive.press(0)
        _ = drive.release(100)
        XCTAssertNil(drive.fire())
        drive.activation.mode = .holdOrDoubleTap
        XCTAssertNil(drive.release(500))
        XCTAssertEqual(drive.press(2000), .stop)
        XCTAssertNil(drive.release(2100))
        XCTAssertNil(drive.finished())
        XCTAssertEqual(drive.press(3000), .start)
        XCTAssertEqual(drive.release(3100), .discard, "hold or double-tap from the next press")
    }

    func testModeChangeMidDoubleTapLockEndsOnTheNextPress() {
        var drive = ActivationDriver(.holdOrDoubleTap)
        _ = drive.press(0)
        _ = drive.release(80)
        _ = drive.press(180)
        _ = drive.release(260)
        drive.activation.mode = .holdOnly
        XCTAssertTrue(drive.isLocked)
        XCTAssertEqual(drive.press(2000), .stop)
        XCTAssertNil(drive.release(2100))
        XCTAssertNil(drive.finished())
        XCTAssertEqual(drive.press(3000), .start)
        XCTAssertNil(drive.release(3100))
        XCTAssertEqual(drive.fire(), .stop, "hold only from the next press")
    }

    /// A press remembered while transcribing belongs to the session under way: it keeps that session's mode.
    func testModeChangeDuringProcessingAppliesOnceTheSessionEnds() {
        var drive = ActivationDriver(.holdOrDoubleTap)
        _ = drive.press(0)
        XCTAssertEqual(drive.release(800), .stop)
        drive.activation.mode = .tapOnly
        XCTAssertNil(drive.press(1500))
        XCTAssertEqual(drive.finished(), .start)
        XCTAssertEqual(drive.release(2000), .stop, "the remembered hold ends on its release")
        XCTAssertNil(drive.finished())
        XCTAssertEqual(drive.press(3000), .start)
        XCTAssertNil(drive.release(3100))
        XCTAssertTrue(drive.isLocked, "tap only once nothing is under way")
    }
}
