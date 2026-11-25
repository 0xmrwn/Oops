@testable import Oops
import OopsCore
import XCTest

/// What the dictation session hands its history, what Paste last reads from it, and pasting a history entry: over
/// the session fakes, with a history that only records its calls.
@MainActor final class DictationHistorySessionTests: XCTestCase {
    private let history = HistorySpy()

    private func dictate(_ run: DictationSessionRun) async throws {
        run.press(0)
        try await run.until { run.drop.states.last == .recording }
        run.release(1_200)
        try await run.until { [.left, .kept, .written].contains(run.drop.states.last) }
    }

    func testAFinishedDictationIsRecordedWithItsLanguage() async throws {
        let run = try DictationSessionRun(self, mode: .holdOnly, language: "fr", history: history.value)
        try await dictate(run)
        XCTAssertEqual(history.recorded, ["Hello fr"])
        XCTAssertGreaterThan(history.durations.first ?? 0, 0, "how long the microphone listened")
    }

    func testADictationWithNoTextFieldIsRecorded() async throws {
        let run = try DictationSessionRun(self, mode: .holdOnly, history: history.value)
        run.inserts.outcome = .refused(.noEditor)
        try await dictate(run)
        XCTAssertEqual(run.drop.states.last, .kept)
        XCTAssertEqual(history.recorded, ["Hello auto"])
    }

    func testWordsRefusedByPolicyAreNotRecorded() async throws {
        for refusal in [InsertRefusal.secureField, .appDenied, .appTurnedOff] {
            let run = try DictationSessionRun(self, mode: .holdOnly, history: history.value)
            run.inserts.outcome = .refused(refusal)
            run.press(0)
            run.release(1_200)
            try await run.until { run.drop.states.count == 3 }
            XCTAssertEqual(run.session.lastTranscript, "Hello", "\(refusal): kept in memory only")
        }
        XCTAssertEqual(history.recorded, [])
    }

    func testTheEntryNamesTheModelReadAtTheStart() async throws {
        history.model = "Whisper"
        let run = try DictationSessionRun(self, mode: .holdOnly, history: history.value)
        run.press(0)
        try await run.until { run.drop.states.last == .recording }
        history.model = "Parakeet"
        run.release(1_200)
        try await run.until { run.drop.states.last == .left }
        XCTAssertEqual(history.recorded, ["Hello auto Whisper"])
    }

    func testACancelledInsertIsNotRecorded() async throws {
        let run = try DictationSessionRun(self, mode: .holdOnly, history: history.value)
        run.inserts.outcome = .refused(.cancelled)
        try await dictate(run)
        XCTAssertEqual(history.recorded, [])
    }

    func testCleanUpWithAIReplacesTheLastEntry() async throws {
        let cleanup = DictationSession.Cleanup(mode: { .basic }, available: { true }, backend: { Answer() }, timeout: .milliseconds(200),
                                               replace: { _, _ in .replaced })
        let run = try DictationSessionRun(self, mode: .holdOnly, engine: FakeSpeechEngine(text: "um hello"), cleanup: cleanup, history: history.value)
        try await dictate(run)
        XCTAssertEqual(run.drop.states.last, .written)
        try XCTUnwrap(run.drop.action).perform()
        try await run.until { run.drop.states.last == .left }
        XCTAssertEqual(history.recorded, ["um hello auto"])
        XCTAssertEqual(history.replaced, ["Hello."])
    }

    func testPasteLastWritesWhatHistoryReturns() async throws {
        history.last = { _ in "From history" }
        let run = try DictationSessionRun(self, mode: .holdOnly, history: history.value)
        XCTAssertTrue(run.session.canPasteLast, "nothing in memory, as after a relaunch")
        run.session.pasteLast()
        try await run.until { run.inserts.texts.count == 1 }
        XCTAssertEqual(run.inserts.texts, ["From history"])
        history.last = { _ in nil }
        XCTAssertFalse(run.session.canPasteLast)
        run.session.pasteLast()
        try await run.settle()
        XCTAssertEqual(run.inserts.texts, ["From history"])
    }

    func testPastingAnEntryWritesItsTextAndRecordsNothing() async throws {
        let run = try DictationSessionRun(self, mode: .holdOnly, history: history.value)
        try await dictate(run)
        run.session.paste("An entry")
        try await run.until { run.inserts.texts.count == 2 }
        try await run.settle()
        XCTAssertEqual(run.inserts.texts, ["Hello", "An entry"])
        XCTAssertEqual(history.recorded, ["Hello auto"])
        XCTAssertEqual(run.session.lastTranscript, "Hello")
        XCTAssertEqual(run.session.lastWritten, "Hello")
        XCTAssertFalse(run.session.holdsDrop)
    }

    func testPastingAnEntryWaitsForNoDictation() async throws {
        let run = try DictationSessionRun(self, mode: .holdOnly, history: history.value)
        run.press(0)
        try await run.until { run.drop.states.last == .recording }
        run.session.paste("An entry")
        try await run.settle()
        XCTAssertEqual(run.inserts.texts, [])
    }

    func testPastingAnEntryWithNoTextFieldOffersToCopyThatEntry() async throws {
        let run = try DictationSessionRun(self, mode: .holdOnly, history: history.value)
        try await dictate(run)
        run.inserts.outcome = .refused(.noEditor)
        run.session.paste("An entry")
        try await run.until { run.drop.states.last == .kept }
        XCTAssertEqual(run.drop.action?.label, "Copy dictation")
        run.drop.action?.perform()
        XCTAssertEqual(run.board.string(forType: .string), "An entry", "the entry, not the last transcript")
        XCTAssertEqual(run.drop.states.last, .copied)
        XCTAssertEqual(run.session.lastTranscript, "Hello")
    }
}

/// Records what the session hands its history, as "text language" ("auto" for none), then the model if any, and the
/// recording's length apart.
@MainActor private final class HistorySpy {
    private(set) var recorded: [String] = []
    private(set) var durations: [Int] = []
    private(set) var replaced: [String] = []
    var model: String?
    var last: (String?) -> String? = { $0 }

    var value: DictationSession.History {
        DictationSession.History(model: { self.model }, record: { text, language, model, durationMs in
            self.recorded.append([text, language ?? "auto", model].compactMap(\.self).joined(separator: " "))
            self.durations.append(durationMs)
        }, replaceLast: { self.replaced.append($0) }, last: { self.last($0) })
    }
}

/// A cleanup model that always answers "Hello.".
private struct Answer: CorrectionBackend {
    func complete(_ text: String, instructions: String, deadline: Duration) async throws -> String { #"{"text":"Hello."}"# }
    func prepare(instructions: String) async {}
}
