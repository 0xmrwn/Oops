@testable import Oops
import OopsCore
import XCTest

/// The modes through the whole session: taps, double taps, a mode changed between presses, and presses
/// made while the previous recording is transcribed.
@MainActor final class DictationSessionModeTests: XCTestCase {
    func testHoldOrTapLatchesOnATapAndTheNextTapInsertsOnce() async throws {
        let run = try DictationSessionRun(self, mode: .holdOrTap)
        run.press(0)
        run.release(100, audio: 500)
        try await run.until { run.session.activation.isRecordingLocked }
        XCTAssertEqual(run.drop.states, [.recording])
        run.press(1_200, audio: 1_600)
        run.release(1_300, audio: 1_700)
        try await run.until { run.drop.states.last == .left }
        try await run.settle()
        XCTAssertEqual(run.drop.states, [.recording, .transcribing, .left])
        XCTAssertEqual(run.inserts.texts, ["Hello"])
    }

    func testHoldOrDoubleTapDiscardsALoneTap() async throws {
        let run = try DictationSessionRun(self, mode: .holdOrDoubleTap)
        run.press(0)
        run.release(120, audio: 520)
        try await run.until { run.drop.states.last == .left }
        try await run.settle()
        XCTAssertEqual(run.drop.states, [.recording, .left])
        XCTAssertEqual(run.inserts.texts, [])
        let transcribed = await run.engine?.transcribed
        XCTAssertEqual(transcribed, 0)
        XCTAssertFalse(run.session.holdsDrop)
    }

    func testAModeChangeAppliesToTheNextPress() async throws {
        let run = try DictationSessionRun(self, mode: .holdOnly)
        run.press(0)
        try await run.until { run.drop.states == [.recording] }
        run.mode = .tapOnly
        // Still hold only: the release ends this recording.
        run.release(1_200)
        try await run.until { run.drop.states.last == .left }
        XCTAssertEqual(run.inserts.texts, ["Hello"])

        // Tap only from the next press: its release changes nothing, the next press ends it.
        run.press(5_000)
        run.release(5_100, audio: 500)
        try await run.until { run.drop.states.count == 4 }
        try await run.settle()
        XCTAssertEqual(run.session.activation.sessionMode, .tapOnly)
        XCTAssertTrue(run.session.activation.isRecording)
        run.press(6_000, audio: 1_600)
        try await run.until { run.drop.states.last == .left && run.inserts.texts.count == 2 }
        XCTAssertEqual(run.drop.states, [.recording, .transcribing, .left, .recording, .transcribing, .left])
    }

    func testAPressDuringATranscriptionRecordsAgainAfterTheInsert() async throws {
        let engine = FakeSpeechEngine(text: "Hello")
        await engine.hold()
        let run = try DictationSessionRun(self, mode: .holdOnly, engine: engine)
        var journal: [String] = []
        run.drop.journal = { journal.append($0) }
        run.inserts.journal = { journal.append($0) }
        run.press(0)
        run.release(1_200)
        try await run.until { await engine.transcribed == 1 }

        // Held while the first is still being transcribed: remembered, nothing opens yet.
        run.press(2_000)
        try await run.settle()
        XCTAssertEqual(run.source.opens, 1)
        XCTAssertEqual(journal, ["recording", "transcribing"])

        await engine.proceed()
        try await run.until { journal.count == 4 }
        XCTAssertEqual(journal, ["recording", "transcribing", "insert Hello", "recording"])
        XCTAssertEqual(run.source.opens, 2)
        run.release(3_200)
        try await run.until { run.inserts.texts.count == 2 && run.drop.states.last == .left }
        XCTAssertEqual(journal, ["recording", "transcribing", "insert Hello", "recording", "transcribing", "insert Hello", "left"])
    }
}
