@testable import Oops
import OopsCore
import XCTest

/// A dictation end to end through OpenAI's realtime transcription engine, against the WebSocket stub on the loopback:
/// the session, its recorder (a WAV file for the microphone), the client and the system's WebSocket. No network, no key.
@MainActor final class RealtimeTranscriptionDictationTests: XCTestCase {
    /// How long the engine waits for the transcript after the release, short so a missing one fails in milliseconds.
    private let timeout = Duration.milliseconds(300)

    private func engine(_ url: URL) -> OpenAIRealtimeEngine {
        OpenAIRealtimeEngine(apiKey: "test-key", endpoint: url, timeout: timeout)
    }

    private func stub(_ script: RealtimeTranscriptionStub.Script) async throws -> RealtimeTranscriptionStub {
        let stub = try await RealtimeTranscriptionStub.start(script)
        addTeardownBlock { await stub.stop() }
        return stub
    }

    private func types(_ stub: RealtimeTranscriptionStub) -> [String] {
        stub.snapshot.frames.compactMap {
            ((try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any])?["type"] as? String
        }
    }

    /// Presses, lets `heard` hold while the key is down, then releases and waits for the drop's last word.
    private func dictate(_ run: DictationLiveRun, until heard: () async -> Bool) async throws {
        run.press(0)
        try await run.until { run.drop.states == [.recording] }
        try await run.until(heard)
        XCTAssertEqual(run.inserts.texts, [], "nothing is written while the key is held")
        run.release(1_200)
        try await run.until { run.drop.states.count == 3 }
    }

    func testACompletedTranscriptIsWrittenOnce() async throws {
        let stub = try await stub(.init(deltas: ["Bonjour", " tout"], ending: .complete("Bonjour tout le monde.")))
        let run = try DictationLiveRun(self, hosted: engine(stub.url), modelPath: .some(nil))
        try await dictate(run) { run.shownWords.contains("Bonjour tout") }
        XCTAssertEqual(run.drop.states, [.recording, .transcribing, .left])
        XCTAssertEqual(run.inserts.texts, ["Bonjour tout le monde."])
        XCTAssertEqual(run.wordsAtInsert, [nil], "the words were gone before the write")
        let sent = types(stub)
        XCTAssertEqual(sent.first, "session.update")
        XCTAssertEqual(sent.filter { $0 == "input_audio_buffer.commit" }.count, 1)
        XCTAssertEqual(stub.snapshot.authorization, "Bearer test-key")
        let local = await (run.engine.opened.count, run.engine.transcribed)
        XCTAssertTrue(local == (0, 0), "nothing local runs for a hosted dictation")
    }

    func testARefusedConnectionEndsInTheFailedDropWithNothingWritten() async throws {
        let refused = try await RealtimeTranscriptionStub.start()
        await refused.stop()
        let run = try DictationLiveRun(self, hosted: engine(refused.url), modelPath: .some(nil))
        try await dictate(run) { true }
        XCTAssertEqual(run.drop.states, [.recording, .transcribing, .failed(.transcription)])
        XCTAssertEqual(run.inserts.texts, [])
        XCTAssertEqual(run.drop.words.last, .some(nil))
        XCTAssertTrue(refused.snapshot.frames.isEmpty)
    }

    func testAnErrorEventEndsInTheFailedDropWithNothingWritten() async throws {
        let stub = try await stub(.init(ending: .errorEvent))
        let run = try DictationLiveRun(self, hosted: engine(stub.url), modelPath: .some(nil))
        try await dictate(run) { self.types(stub).contains("session.update") }
        XCTAssertEqual(run.drop.states, [.recording, .transcribing, .failed(.transcription)])
        XCTAssertEqual(run.inserts.texts, [])
        XCTAssertFalse(types(stub).contains("input_audio_buffer.commit"), "a failed session is never committed")
    }

    func testNoCompletionEndsInTheFailedDropWithNothingWritten() async throws {
        let stub = try await stub(.init(ending: .silent))
        let run = try DictationLiveRun(self, hosted: engine(stub.url), modelPath: .some(nil))
        let began = ContinuousClock.now
        try await dictate(run) { self.types(stub).contains("input_audio_buffer.append") }
        XCTAssertEqual(run.drop.states, [.recording, .transcribing, .failed(.transcription)])
        XCTAssertEqual(run.inserts.texts, [])
        XCTAssertEqual(types(stub).filter { $0 == "input_audio_buffer.commit" }.count, 1)
        XCTAssertLessThan(ContinuousClock.now - began, .seconds(3), "the engine's timeout ended it, not the test's")
    }
}
