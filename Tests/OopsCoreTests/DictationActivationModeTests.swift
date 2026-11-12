import XCTest
@testable import OopsCore

/// Each mode's start, latch and stop, as the app sees them.
final class DictationActivationModeTests: XCTestCase {
    func testModesKeepTheirStoredValues() {
        XCTAssertEqual(DictationMode.allCases.map(\.rawValue), ["holdOrTap", "holdOrDoubleTap", "holdOnly", "tapOnly"])
        XCTAssertEqual(DictationActivation().mode, .holdOrTap)
        XCTAssertEqual(DictationActivation.holdThreshold, .milliseconds(300))
    }

    // Hold or tap.

    func testHoldOrTapHoldStopsOnReleaseAfterTheGrace() {
        var drive = ActivationDriver(.holdOrTap)
        XCTAssertEqual(drive.press(0), .start)
        XCTAssertTrue(drive.isRecording)
        XCTAssertNil(drive.release(800))
        XCTAssertEqual(drive.deadline, drive.at(850), "a release waits out the 50 ms grace")
        XCTAssertNil(drive.activation.timerFired(at: drive.at(849)), "the timer does nothing before its deadline")
        XCTAssertEqual(drive.activation.timerFired(at: drive.at(850)), .stop)
        XCTAssertNil(drive.deadline)
        XCTAssertFalse(drive.isRecording)
        XCTAssertNil(drive.finished())
    }

    func testHoldOrTapTapLatchesUntilTheNextPress() {
        var drive = ActivationDriver(.holdOrTap)
        XCTAssertEqual(drive.press(0), .start)
        XCTAssertNil(drive.release(120))
        XCTAssertNil(drive.fire())
        XCTAssertTrue(drive.isRecording)
        XCTAssertTrue(drive.isLocked)
        XCTAssertNil(drive.release(2000), "a latched recording ignores releases")
        XCTAssertNil(drive.deadline)
        XCTAssertEqual(drive.press(5000), .stop)
        XCTAssertFalse(drive.isRecording)
        XCTAssertNil(drive.release(5080))
        XCTAssertNil(drive.finished())
        XCTAssertEqual(drive.press(6000), .start)
    }

    // Hold only.

    func testHoldOnlyHoldStopsOnRelease() {
        var drive = ActivationDriver(.holdOnly)
        XCTAssertEqual(drive.press(0), .start)
        XCTAssertNil(drive.release(1000))
        XCTAssertEqual(drive.fire(), .stop)
    }

    func testHoldOnlyTapDoesNotLatch() {
        var drive = ActivationDriver(.holdOnly)
        XCTAssertEqual(drive.press(0), .start)
        XCTAssertNil(drive.release(40))
        XCTAssertFalse(drive.isLocked)
        XCTAssertEqual(drive.fire(), .stop, "even a 40 ms tap stops: hold only never latches")
        XCTAssertFalse(drive.isRecording)
    }

    // Tap only.

    func testTapOnlyPressStartsAndTheNextPressStops() {
        var drive = ActivationDriver(.tapOnly)
        XCTAssertEqual(drive.press(0), .start)
        XCTAssertTrue(drive.isLocked, "tap only is latched from the press")
        XCTAssertNil(drive.release(100))
        XCTAssertNil(drive.deadline, "tap only never defers a release")
        XCTAssertNil(drive.release(3000))
        XCTAssertTrue(drive.isRecording)
        XCTAssertEqual(drive.press(4000), .stop)
        XCTAssertNil(drive.release(4100))
        XCTAssertNil(drive.finished())
        XCTAssertFalse(drive.isRecording)
    }

    func testTapOnlyLongHoldStillLatches() {
        var drive = ActivationDriver(.tapOnly)
        XCTAssertEqual(drive.press(0), .start)
        XCTAssertNil(drive.release(2000))
        XCTAssertTrue(drive.isLocked)
        XCTAssertEqual(drive.press(3000), .stop)
    }

    // Hold or double-tap.

    func testHoldOrDoubleTapHoldStopsOnRelease() {
        var drive = ActivationDriver(.holdOrDoubleTap)
        XCTAssertEqual(drive.press(0), .start)
        XCTAssertFalse(drive.isLocked)
        XCTAssertEqual(drive.release(800), .stop, "a release decides at once: no grace in this mode")
        XCTAssertNil(drive.deadline)
        XCTAssertFalse(drive.isRecording)
        XCTAssertNil(drive.finished())
    }

    func testHoldOrDoubleTapDoubleTapLatchesUntilTheNextPress() {
        var drive = ActivationDriver(.holdOrDoubleTap)
        XCTAssertEqual(drive.press(0), .start)
        XCTAssertEqual(drive.release(80), .discard)
        XCTAssertEqual(drive.press(180), .start)
        XCTAssertNil(drive.release(260))
        XCTAssertTrue(drive.isLocked)
        XCTAssertEqual(drive.press(3000), .stop)
        XCTAssertNil(drive.release(3080))
        XCTAssertNil(drive.finished())
        XCTAssertFalse(drive.isRecording)
    }
}
