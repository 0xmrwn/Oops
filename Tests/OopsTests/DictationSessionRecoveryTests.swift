import AppKit
import Carbon
@testable import Oops
import OopsCore
import XCTest

/// Getting out of a dictation and getting its text back: Escape in a hold and in a latch, silence, a
/// microphone that goes away, no text field, and Paste last dictation.
@MainActor final class DictationSessionRecoveryTests: XCTestCase {
    private let controlCommand = UInt32(controlKey | cmdKey)

    func testEscapeIsRegisteredWithTheHeldShortcutsModifiersOnlyWhileRecording() async throws {
        let run = try DictationSessionRun(self, mode: .holdOnly)
        run.shortcutModifiers = controlCommand
        run.press(0)
        try await run.until { run.drop.states == [.recording] }
        XCTAssertEqual(run.escapes, [[0, controlCommand]])
        run.release(1_200)
        try await run.until { run.drop.states.last == .left }
        XCTAssertEqual(run.escapes, [[0, controlCommand], []], "gone once the recording ends")
    }

    func testAnOptionCommandShortcutNeverRegistersForceQuit() async throws {
        let run = try DictationSessionRun(self, mode: .holdOnly)
        run.shortcutModifiers = UInt32(optionKey | cmdKey)
        run.press(0)
        try await run.until { run.drop.states == [.recording] }
        XCTAssertEqual(run.escapes, [[0]])
    }

    func testALatchedRecordingRegistersPlainEscape() async throws {
        let run = try DictationSessionRun(self, mode: .holdOrTap)
        run.shortcutModifiers = controlCommand
        run.press(0)
        run.release(100, audio: 500)
        try await run.until { run.session.activation.isRecordingLocked }
        try await run.settle()
        XCTAssertEqual(run.escapes.last, [0])
    }

    func testEscapeDuringAHoldWritesNothingAndClosesTheMicrophone() async throws {
        let run = try DictationSessionRun(self, mode: .holdOrTap)
        run.shortcutModifiers = controlCommand
        run.press(0)
        try await run.until { run.drop.states == [.recording] }
        run.session.cancel()
        try await run.until { run.drop.states.last == .left }
        // The held keys come up after the cancel: their release ends nothing.
        run.release(1_200)
        try await run.settle()
        XCTAssertEqual(run.drop.states, [.recording, .left])
        XCTAssertEqual(run.inserts.texts, [])
        let transcribed = await run.engine?.transcribed, open = await run.recorder.isSourceOpen
        XCTAssertEqual(transcribed, 0)
        XCTAssertFalse(open, "the microphone closes with the cancel, not after the keep-alive")
        XCTAssertEqual(run.source.closes, 1)
        XCTAssertEqual(run.escapes.last, [])
        XCTAssertFalse(run.session.holdsDrop)
    }

    func testEscapeDuringALatchWritesNothingAndTheNextPressRecords() async throws {
        let run = try DictationSessionRun(self, mode: .holdOrTap)
        run.press(0)
        run.release(100, audio: 500)
        try await run.until { run.session.activation.isRecordingLocked }
        run.session.cancel()
        try await run.until { run.drop.states.last == .left }
        XCTAssertEqual(run.inserts.texts, [])
        XCTAssertFalse(run.session.activation.isRecording)
        run.press(3_000)
        run.release(4_200)
        try await run.until { run.inserts.texts == ["Hello"] && run.drop.states.last == .left }
        XCTAssertEqual(run.drop.states, [.recording, .left, .recording, .transcribing, .left])
    }

    func testEscapeWithNothingRecordingDoesNothing() async throws {
        let run = try DictationSessionRun(self, mode: .holdOnly)
        run.session.cancel()
        try await run.settle()
        XCTAssertEqual(run.drop.states, [])
        XCTAssertEqual(run.source.opens, 0)
    }

    func testASilentLatchedRecordingWritesNothing() async throws {
        let quiet = (0 ..< 48_000).map { Float(0.000_7) * sin(2 * Float.pi * 220 * Float($0) / 16_000) }
        let run = try DictationSessionRun(self, mode: .holdOrTap, audio: quiet)
        run.press(0)
        run.release(100, audio: 500)
        try await run.until { run.session.activation.isRecordingLocked }
        run.press(1_200, audio: 1_600)
        run.release(1_300, audio: 1_700)
        try await run.until { run.drop.states.last == .left }
        try await run.settle()
        XCTAssertEqual(run.drop.states, [.recording, .transcribing, .left])
        XCTAssertEqual(run.inserts.texts, [])
        XCTAssertNil(run.session.lastTranscript)
    }

    func testLosingTheMicrophoneEndsTheRecordingAndWritesWhatItHeard() async throws {
        let run = try DictationSessionRun(self, mode: .holdOnly)
        run.press(0)
        try await run.until { run.drop.states == [.recording] }
        run.source.lose()
        try await run.until { run.drop.states.last == .left }
        XCTAssertEqual(run.drop.states, [.recording, .transcribing, .left])
        XCTAssertEqual(run.inserts.texts, ["Hello"])
        // The keys come up later: nothing more is written.
        run.release(2_000)
        try await run.settle()
        XCTAssertEqual(run.inserts.texts, ["Hello"])
        // The next dictation opens the input again, on whatever is the default now.
        run.press(5_000)
        run.release(6_200)
        try await run.until { run.inserts.texts.count == 2 }
        XCTAssertEqual(run.source.opens, 2)
    }

    func testNoTextFieldKeepsTheTranscriptAndCopyPutsItOnTheClipboard() async throws {
        let run = try DictationSessionRun(self, mode: .holdOnly)
        run.inserts.outcome = .refused(.noEditor)
        run.press(0)
        run.release(1_200)
        try await run.until { run.drop.states.count == 3 }
        XCTAssertEqual(run.drop.states, [.recording, .transcribing, .kept])
        XCTAssertNil(run.board.string(forType: .string))
        XCTAssertEqual(run.drop.action?.label, "Copy dictation")
        run.drop.action?.perform()
        XCTAssertEqual(run.board.string(forType: .string), "Hello")
        XCTAssertEqual(run.drop.states.last, .copied)
    }

    func testPasteLastWritesThePreviousTranscriptAgain() async throws {
        let run = try DictationSessionRun(self, mode: .holdOnly)
        run.inserts.outcome = .refused(.noEditor)
        run.press(0)
        run.release(1_200)
        try await run.until { run.drop.states.last == .kept }
        run.inserts.outcome = .inserted
        run.session.pasteLast()
        try await run.until { run.inserts.texts.count == 2 }
        XCTAssertEqual(run.inserts.texts, ["Hello", "Hello"])
        XCTAssertEqual(run.drop.states.last, .kept, "a written paste shows nothing")
    }

    func testPasteLastWithNoFieldOffersCopyAgain() async throws {
        let run = try DictationSessionRun(self, mode: .holdOnly)
        run.press(0)
        run.release(1_200)
        try await run.until { run.drop.states.last == .left }
        run.inserts.outcome = .refused(.noEditor)
        run.session.pasteLast()
        try await run.until { run.drop.states.last == .kept }
        XCTAssertEqual(run.inserts.texts, ["Hello", "Hello"])
    }

    func testPasteLastWithNothingKeptWritesNothing() async throws {
        let run = try DictationSessionRun(self, mode: .holdOnly)
        run.session.pasteLast()
        try await run.settle()
        XCTAssertEqual(run.inserts.texts, [])
        XCTAssertEqual(run.drop.states, [])
    }

    func testPasteLastNeverReachesPastARecording() async throws {
        let run = try DictationSessionRun(self, mode: .holdOnly)
        run.press(0)
        run.release(1_200)
        try await run.until { run.drop.states.last == .left }
        run.press(3_000)
        try await run.until { run.drop.states.last == .recording }
        run.session.pasteLast()
        try await run.settle()
        XCTAssertEqual(run.inserts.texts, ["Hello"])
    }

    func testACancelledInsertLeavesTheLastTranscriptAlone() async throws {
        let run = try DictationSessionRun(self, mode: .holdOnly)
        run.inserts.outcome = .refused(.cancelled)
        run.press(0)
        run.release(1_200)
        try await run.until { run.drop.states.last == .left }
        XCTAssertNil(run.session.lastTranscript)
    }
}
