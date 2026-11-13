import Carbon
import XCTest
@testable import OopsCore

/// Escape's registration while a recording runs, cancel in a hold and in a latch, and a recording whose
/// input went away.
final class DictationCoordinatorCancelTests: XCTestCase {
    private let controlCommand = UInt32(controlKey | cmdKey)
    private let optionCommand = UInt32(optionKey | cmdKey)

    func testEscapeIsRegisteredOnlyWhileRecording() {
        XCTAssertEqual(DictationEscape.modifiers(shortcut: controlCommand, recording: false, locked: false), [])
        XCTAssertEqual(DictationEscape.modifiers(shortcut: controlCommand, recording: false, locked: true), [])
    }

    func testAHeldShortcutAddsEscapeWithItsModifiers() {
        XCTAssertEqual(DictationEscape.modifiers(shortcut: controlCommand, recording: true, locked: false), [0, controlCommand])
        let shiftOption = UInt32(shiftKey | optionKey)
        XCTAssertEqual(DictationEscape.modifiers(shortcut: shiftOption, recording: true, locked: false), [0, shiftOption])
    }

    func testOptionCommandHeldNeverTakesForceQuit() {
        XCTAssertEqual(DictationEscape.modifiers(shortcut: optionCommand, recording: true, locked: false), [0])
        let hyper = UInt32(cmdKey | optionKey | controlKey | shiftKey)
        XCTAssertEqual(DictationEscape.modifiers(shortcut: hyper, recording: true, locked: false), [0], "⌥⌘ among others")
    }

    func testALatchedRecordingTakesPlainEscapeOnly() {
        XCTAssertEqual(DictationEscape.modifiers(shortcut: controlCommand, recording: true, locked: true), [0])
        XCTAssertEqual(DictationEscape.modifiers(shortcut: optionCommand, recording: true, locked: true), [0])
        XCTAssertEqual(DictationEscape.modifiers(shortcut: nil, recording: true, locked: false), [0])
    }

    func testCancelWhileHeldEndsTheRecordingAndItsReleaseDoesNothing() {
        for mode in [DictationMode.holdOrTap, .holdOnly, .holdOrDoubleTap] {
            var drive = ActivationDriver(mode)
            XCTAssertEqual(drive.press(0), .start, "\(mode)")
            XCTAssertFalse(drive.isLocked, "\(mode)")
            drive.activation.cancel(recordingWasActive: true)
            XCTAssertFalse(drive.isRecording, "\(mode)")
            XCTAssertNotEqual(drive.release(1_000), .stop, "\(mode): the cancelled hold's release transcribes nothing")
            XCTAssertNil(drive.fire(), "\(mode)")
            XCTAssertEqual(drive.press(3_000), .start, "\(mode): the next press records again")
        }
    }

    func testCancelWhileLatchedEndsTheRecording() {
        var drive = ActivationDriver(.holdOrTap)
        XCTAssertEqual(drive.press(0), .start)
        XCTAssertNil(drive.release(100))
        XCTAssertNil(drive.fire())
        XCTAssertTrue(drive.isLocked)
        drive.activation.cancel(recordingWasActive: true)
        XCTAssertFalse(drive.isRecording)
        XCTAssertEqual(drive.press(2_000), .start, "a press after the cancel starts, never stops")

        var tap = ActivationDriver(.tapOnly)
        XCTAssertEqual(tap.press(0), .start)
        tap.activation.cancel(recordingWasActive: true)
        XCTAssertEqual(tap.press(2_000), .start)
    }

    func testAnInputLostStopsTheRecordingInEveryMode() {
        for mode in DictationMode.allCases {
            var drive = ActivationDriver(mode)
            XCTAssertEqual(drive.press(0), .start, "\(mode)")
            XCTAssertEqual(drive.activation.inputLost(), .stop, "\(mode)")
            XCTAssertFalse(drive.isRecording, "\(mode)")
            XCTAssertNil(drive.release(800), "\(mode): the key's release finds the transcription under way")
            XCTAssertNil(drive.fire(), "\(mode)")
            XCTAssertNil(drive.finished(), "\(mode)")
            XCTAssertEqual(drive.press(3_000), .start, "\(mode): the next press records again")
        }
    }

    func testAnInputLostDuringALatchStopsIt() {
        var drive = ActivationDriver(.holdOrTap)
        XCTAssertEqual(drive.press(0), .start)
        XCTAssertNil(drive.release(100))
        XCTAssertNil(drive.fire())
        XCTAssertEqual(drive.activation.inputLost(), .stop)
        XCTAssertNil(drive.press(1_000), "remembered for after the transcription, as any busy press")
    }

    func testAnInputLostWithNothingRecordingDoesNothing() {
        var drive = ActivationDriver(.holdOrTap)
        XCTAssertNil(drive.activation.inputLost())
        XCTAssertEqual(drive.press(0), .start)
        XCTAssertEqual(drive.release(800), nil)
        XCTAssertEqual(drive.fire(), .stop)
        XCTAssertNil(drive.activation.inputLost(), "already transcribing")
    }

    func testTheCoordinatorEndsALostRecordingAsItsReleaseWould() {
        var state = DictationCoordinator()
        let now = ContinuousClock.now
        XCTAssertTrue(state.onInput(pttInput(true), now: now).isStart)
        XCTAssertNil(state.onInput(pttInput(false), now: now + .milliseconds(100)), "deferred by the grace")
        XCTAssertTrue(state.onInputLost().isStop)
        XCTAssertEqual(state.stage, .processing)
        XCTAssertNil(state.graceDeadline, "the deferred release is spent")
        XCTAssertNil(state.onInputLost())
    }
}
