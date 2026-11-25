@testable import Oops
import OopsCore
import XCTest

/// Dictate in an app the person turned Oops off in: refused at the press, before the microphone opens, whether
/// the shortcut is held or tapped to lock; and refused at the write when focus moved there meanwhile.
@MainActor final class DictationTurnedOffTests: XCTestCase {
    private let notes = TurnedOffApp(name: "Notes", bundleID: "com.apple.Notes")
    private var recorded: [String] = []
    private var history: DictationSession.History {
        DictationSession.History(model: { nil }, record: { [weak self] text, _, _ in self?.recorded.append(text) },
                                 replaceLast: { _ in }, last: { $0 })
    }

    private func assertRefusedBeforeListening(_ run: DictationSessionRun) async throws {
        try await run.until { run.drop.states.contains(.failed(.turnedOff(notes))) }
        try await run.settle()
        XCTAssertEqual(run.drop.states, [.failed(.turnedOff(notes))])
        XCTAssertEqual(run.drop.action?.label, "Turn on in Notes")
        XCTAssertEqual(run.source.opens, 0, "the microphone never opened")
        let transcribed = await run.engine?.transcribed
        XCTAssertEqual(transcribed, 0)
        XCTAssertEqual(run.inserts.texts, [])
        XCTAssertEqual(recorded, [])
        XCTAssertFalse(run.session.holdsDrop)
        XCTAssertFalse(run.session.activation.isRecording)
    }

    func testAHeldPressIsRefusedBeforeRecording() async throws {
        let run = try DictationSessionRun(self, mode: .holdOnly, history: history)
        run.turnedOff = notes
        run.press(0)
        run.release(1_200)
        try await assertRefusedBeforeListening(run)
    }

    func testATapToLockIsRefusedBeforeRecording() async throws {
        let run = try DictationSessionRun(self, mode: .holdOrTap, history: history)
        run.turnedOff = notes
        run.press(0)
        run.release(100)
        try await assertRefusedBeforeListening(run)
    }

    func testOnInTheAppItRecordsAsBefore() async throws {
        let run = try DictationSessionRun(self, mode: .holdOnly, history: history)
        run.press(0)
        run.release(1_200)
        try await run.until { run.drop.states.last == .left }
        XCTAssertEqual(run.drop.states, [.recording, .transcribing, .left])
        XCTAssertEqual(run.source.opens, 1)
        XCTAssertEqual(run.inserts.texts, ["Hello"])
        XCTAssertEqual(recorded, ["Hello"])
    }

    func testFocusMovedToAnAppOopsIsOffInRefusesTheWrite() async throws {
        let run = try DictationSessionRun(self, mode: .holdOnly, history: history)
        run.inserts.outcome = .turnedOff(notes)
        run.press(0)
        run.release(1_200)
        try await run.until { run.drop.states.count == 3 }
        XCTAssertEqual(run.drop.states, [.recording, .transcribing, .failed(.turnedOff(notes))])
        XCTAssertEqual(run.drop.action?.label, "Turn on in Notes")
        XCTAssertEqual(recorded, [], "words refused in an app kept from writing never reach the disk")
        XCTAssertEqual(run.session.lastTranscript, "Hello", "kept for Paste last dictation")
    }
}
