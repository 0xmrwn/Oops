import XCTest
@testable import OopsCore

/// Hex's tests of the double-tap lock and the hold-versus-tap boundary (`src/suppression/tests.rs` and
/// `src/dictation.rs` at v3.4.0), on a key chord. Hex's machine answers `Finish` and its capture then discards a
/// recording shorter than the hold threshold; here the two are one answer, so each `Finish` reads `.stop` or
/// `.discard` by that same rule.
final class DictationActivationHexTests: XCTestCase {
    func testCallbackTimestampsPreserveNanosecondsAndShortTapDiscard() {
        var drive = ActivationDriver(.holdOrDoubleTap)
        XCTAssertEqual(drive.press(0), .start)
        XCTAssertEqual(drive.release(80), .discard)
    }

    func testCallbackDoubleTapLocksForModifierAndKeyBindings() {
        var drive = ActivationDriver(.holdOrDoubleTap)
        var discarded = 0
        var clips = 0
        let edges: [(Int64, Bool, DictationActivation.Effect?, Bool)] = [
            (0, true, .start, true),
            (80, false, .discard, false),
            (180, true, .start, true),
            (260, false, nil, true),
            (1000, true, .stop, false),
            (1080, false, nil, false),
        ]
        for (millis, down, expected, recording) in edges {
            let effect = down ? drive.press(millis) : drive.release(millis)
            XCTAssertEqual(effect, expected, "at \(millis) ms")
            if effect == .discard { discarded += 1 }
            if effect == .stop { clips += 1 }
            XCTAssertEqual(drive.isRecording, recording, "at \(millis) ms")
        }
        XCTAssertFalse(drive.isRecording)
        XCTAssertEqual(discarded, 1)
        XCTAssertEqual(clips, 1)
    }

    func testCallbackHoldAndDoubleTapBoundariesAreMilliseconds() {
        for duration in [299, 300, 301] as [Int64] {
            var hold = ActivationDriver(.holdOrDoubleTap)
            _ = hold.press(0)
            XCTAssertEqual(hold.release(duration) == .discard, duration < 300, "held \(duration) ms")

            var drive = ActivationDriver(.holdOrDoubleTap)
            _ = drive.press(0)
            _ = drive.release(80)
            _ = drive.press(180)
            _ = drive.release(80 + duration)
            XCTAssertEqual(drive.isRecording, duration < 300, "second release \(duration) ms after the first")
        }
    }

    /// Hex's interleaved mouse-down while locked is dropped: Oops has no such input.
    func testOptionDoubleTapLocksUntilOptionIsPressedAgain() {
        var drive = ActivationDriver(.holdOrDoubleTap)
        XCTAssertEqual(drive.press(0), .start)
        XCTAssertEqual(drive.release(80), .discard)
        XCTAssertEqual(drive.press(180), .start)
        XCTAssertNil(drive.release(260))
        XCTAssertTrue(drive.isRecording)
        XCTAssertEqual(drive.press(2000), .stop)
        XCTAssertFalse(drive.isRecording)
    }

    func testOptionDoubleTapStillLocks() {
        var drive = ActivationDriver(.holdOrDoubleTap)
        XCTAssertEqual(drive.press(0), .start)
        XCTAssertEqual(drive.release(80), .discard)
        XCTAssertEqual(drive.press(150), .start)
        XCTAssertNil(drive.release(230))
        XCTAssertTrue(drive.isLocked)
        XCTAssertEqual(drive.press(1000), .stop)
        XCTAssertNil(drive.release(1080))
        XCTAssertFalse(drive.isRecording)
    }

    func testOptionPressAndReleaseFinishes() {
        var drive = ActivationDriver(.holdOrDoubleTap)
        XCTAssertEqual(drive.press(0), .start)
        XCTAssertEqual(drive.release(1000), .stop)
    }

    func testKeyChordStartsOnKeyDownAndFinishesOnKeyUp() {
        var drive = ActivationDriver(.holdOrDoubleTap)
        XCTAssertEqual(drive.press(0), .start)
        XCTAssertEqual(drive.release(1000), .stop)
    }

    func testKeyChordDoubleTapLocksUntilTheChordIsPressedAgain() {
        var drive = ActivationDriver(.holdOrDoubleTap)
        XCTAssertEqual(drive.press(0), .start)
        XCTAssertEqual(drive.release(70), .discard)
        XCTAssertEqual(drive.press(150), .start)
        XCTAssertNil(drive.release(230))
        XCTAssertTrue(drive.isRecording)
        XCTAssertEqual(drive.press(1000), .stop)
    }

    /// Only Hex's double-tap-enabled case applies: with the lock off, the mode is hold only. Its `Finish` is a
    /// discard here because the second press was held 270 ms.
    func testSecondTapFinishesAsPressAndHoldWhenDoubleTapCannotLock() {
        var drive = ActivationDriver(.holdOrDoubleTap)
        _ = drive.press(0)
        _ = drive.release(80)
        _ = drive.press(180)
        XCTAssertEqual(drive.release(450), .discard)
        XCTAssertFalse(drive.isRecording)
    }

    func testQuickOptionTapDiscards() {
        var drive = ActivationDriver(.holdOrDoubleTap)
        _ = drive.press(0)
        XCTAssertEqual(drive.release(100), .discard)
    }

    func testShortTapDiscardsOnItsPhysicalReleaseDespiteTheTail() {
        var drive = ActivationDriver(.holdOrDoubleTap)
        _ = drive.press(0)
        XCTAssertEqual(drive.release(299), .discard)
        XCTAssertFalse(drive.isRecording)
    }

    func testMinimumHoldUsesSourceEventTimesAfterAProcessingStall() {
        var short = ActivationDriver(.holdOrDoubleTap)
        _ = short.press(0)
        XCTAssertEqual(short.release(299), .discard)

        var accepted = ActivationDriver(.holdOrDoubleTap)
        _ = accepted.press(0)
        XCTAssertEqual(accepted.release(300), .stop)
    }
}
