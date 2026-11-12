import XCTest
@testable import OopsCore

/// Hold or double-tap: the discard, the lock, the window's edges, the timer, and presses while the previous
/// recording is transcribed.
final class DictationActivationDoubleTapTests: XCTestCase {
    func testLoneQuickTapDiscardsAndLeavesIdle() {
        var drive = ActivationDriver(.holdOrDoubleTap)
        XCTAssertEqual(drive.press(0), .start)
        XCTAssertEqual(drive.release(120), .discard)
        XCTAssertFalse(drive.isRecording)
        XCTAssertNil(drive.finished(), "a discard expects no transcription")
        XCTAssertTrue(drive.activation.doubleTap.isIdle)
        // Long after the window, the next press is a fresh hold.
        XCTAssertEqual(drive.press(2000), .start)
        XCTAssertEqual(drive.release(3000), .stop)
    }

    func testHoldBoundaryOnBothSides() {
        for (held, expected) in [(299, DictationActivation.Effect.discard), (300, .stop)] {
            var drive = ActivationDriver(.holdOrDoubleTap)
            XCTAssertEqual(drive.press(0), .start)
            XCTAssertEqual(drive.release(Int64(held)), expected, "held \(held) ms")
        }
    }

    /// The lock needs the second release less than 300 ms after the first release.
    func testSecondReleaseBoundaryOnBothSides() {
        for (secondRelease, locks) in [(379, true), (380, false)] {
            var drive = ActivationDriver(.holdOrDoubleTap)
            XCTAssertEqual(drive.press(0), .start)
            XCTAssertEqual(drive.release(80), .discard)
            XCTAssertEqual(drive.press(180), .start)
            XCTAssertEqual(drive.release(Int64(secondRelease)), locks ? nil : .discard, "\(secondRelease) ms")
            XCTAssertEqual(drive.isLocked, locks)
            XCTAssertEqual(drive.isRecording, locks)
        }
    }

    /// A second press 300 ms or more after the first release pairs with nothing, so even a quick release
    /// cannot lock.
    func testSecondPressBoundaryOnBothSides() {
        for (secondPress, locks) in [(379, true), (380, false)] {
            var drive = ActivationDriver(.holdOrDoubleTap)
            XCTAssertEqual(drive.press(0), .start)
            XCTAssertEqual(drive.release(80), .discard)
            XCTAssertEqual(drive.press(Int64(secondPress)), .start)
            // A release at the same instant: zero time after the press, inside the window only if it paired.
            XCTAssertEqual(drive.release(Int64(secondPress)), locks ? nil : .discard, "\(secondPress) ms")
            XCTAssertEqual(drive.isLocked, locks)
        }
    }

    /// A slow second release finishes as a hold: transcribed when the second press was held long enough.
    func testHeldSecondTapStopsAsAHold() {
        var drive = ActivationDriver(.holdOrDoubleTap)
        XCTAssertEqual(drive.press(0), .start)
        XCTAssertEqual(drive.release(80), .discard)
        XCTAssertEqual(drive.press(180), .start)
        XCTAssertEqual(drive.release(1200), .stop)
        XCTAssertFalse(drive.isRecording)
    }

    /// A release that ends a transcribed hold opens the window too, as in Hex.
    func testQuickTapAfterAHoldLocks() {
        var drive = ActivationDriver(.holdOrDoubleTap)
        XCTAssertEqual(drive.press(0), .start)
        XCTAssertEqual(drive.release(1000), .stop)
        XCTAssertNil(drive.finished())
        XCTAssertEqual(drive.press(1100), .start)
        XCTAssertNil(drive.release(1200))
        XCTAssertTrue(drive.isLocked)
    }

    func testPressWhileHeldAndReleaseWhileLockedDoNothing() {
        var drive = ActivationDriver(.holdOrDoubleTap)
        XCTAssertEqual(drive.press(0), .start)
        XCTAssertNil(drive.press(100), "the key is already down")
        XCTAssertTrue(drive.isRecording)
        XCTAssertEqual(drive.release(480), .stop)

        var locked = ActivationDriver(.holdOrDoubleTap)
        _ = locked.press(0)
        _ = locked.release(80)
        _ = locked.press(180)
        XCTAssertNil(locked.release(260))
        XCTAssertNil(locked.release(900))
        XCTAssertTrue(locked.isLocked)
    }

    /// A finishing press that comes less than 300 ms after the locked recording began is itself a tap: Hex
    /// discards it.
    func testQuickTripleTapDiscardsTheLockedRecording() {
        var drive = ActivationDriver(.holdOrDoubleTap)
        _ = drive.press(0)
        _ = drive.release(50)
        XCTAssertEqual(drive.press(100), .start)
        XCTAssertNil(drive.release(150))
        XCTAssertEqual(drive.press(399), .discard)
        XCTAssertFalse(drive.isRecording)
        XCTAssertNil(drive.release(450), "the finishing press's release opens no window")
        XCTAssertEqual(drive.press(500), .start)
        XCTAssertEqual(drive.release(550), .discard, "nothing to pair with: a lone tap again")
    }

    func testDeadlineIsNeverSetAndTheTimerDoesNothing() {
        var drive = ActivationDriver(.holdOrDoubleTap)
        let steps: [(inout ActivationDriver) -> DictationActivation.Effect?] = [
            { $0.press(0) }, { $0.release(80) }, { $0.press(180) }, { $0.release(260) }, { $0.press(1000) },
            { $0.release(1080) }, { $0.finished() },
        ]
        for step in steps {
            _ = step(&drive)
            XCTAssertNil(drive.deadline)
            XCTAssertNil(drive.activation.timerFired(at: drive.at(5000)))
        }
        XCTAssertFalse(drive.isRecording)
    }

    // A busy pipeline: presses made while the previous recording is transcribed.

    /// Into processing by a 1 s hold released at 1000 ms.
    private func intoProcessing() -> ActivationDriver {
        var drive = ActivationDriver(.holdOrDoubleTap)
        XCTAssertEqual(drive.press(0), .start)
        XCTAssertEqual(drive.release(1000), .stop)
        return drive
    }

    func testHeldPressDuringProcessingStartsAtTheDrainMeasuredFromKeyDown() {
        var drive = intoProcessing()
        XCTAssertNil(drive.press(2000))
        XCTAssertEqual(drive.finished(), .start)
        XCTAssertTrue(drive.isRecording)
        XCTAssertEqual(drive.release(2350), .stop, "held 350 ms since the real key-down")
    }

    func testBusyTapStartsNothing() {
        var drive = intoProcessing()
        XCTAssertNil(drive.press(2000))
        XCTAssertNil(drive.release(2100))
        XCTAssertNil(drive.finished())
        XCTAssertFalse(drive.isRecording)
    }

    func testBusyHoldReleasedBeforeTheDrainStartsNothing() {
        var drive = intoProcessing()
        XCTAssertNil(drive.press(2000))
        XCTAssertNil(drive.release(2600))
        XCTAssertNil(drive.finished())
        XCTAssertFalse(drive.isRecording)
    }

    func testBusyDoubleTapStartsLockedAtTheDrain() {
        var drive = intoProcessing()
        XCTAssertNil(drive.press(2000))
        XCTAssertNil(drive.release(2080))
        XCTAssertNil(drive.press(2180))
        XCTAssertNil(drive.release(2260))
        XCTAssertEqual(drive.finished(), .start)
        XCTAssertTrue(drive.isLocked)
        XCTAssertEqual(drive.press(4000), .stop)
    }

    func testPressOnABusyDoubleTapForgetsIt() {
        var drive = intoProcessing()
        _ = drive.press(2000)
        _ = drive.release(2080)
        _ = drive.press(2180)
        _ = drive.release(2260)
        XCTAssertNil(drive.press(2600))
        XCTAssertNil(drive.release(2650), "the forgetting press's release opens no window")
        XCTAssertNil(drive.finished())
        XCTAssertFalse(drive.isRecording)
    }

    /// A tap during processing whose release falls inside the window of the release that stopped the hold.
    func testQuickTapRightAfterAStopLocksAtTheDrain() {
        var drive = intoProcessing()
        XCTAssertNil(drive.press(1100))
        XCTAssertNil(drive.release(1200))
        XCTAssertEqual(drive.finished(), .start)
        XCTAssertTrue(drive.isLocked)
    }

    func testDrainBeforeTheReleaseOfAStoppingPressIgnoresIt() {
        var drive = ActivationDriver(.holdOrDoubleTap)
        _ = drive.press(0)
        _ = drive.release(80)
        _ = drive.press(180)
        _ = drive.release(260)
        XCTAssertEqual(drive.press(2000), .stop)
        XCTAssertNil(drive.finished())
        XCTAssertNil(drive.release(2100))
        XCTAssertFalse(drive.isRecording)
        XCTAssertEqual(drive.press(2200), .start)
        XCTAssertEqual(drive.release(2250), .discard, "the stopping press's release opened no window")
    }
}
