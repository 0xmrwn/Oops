@testable import Oops
import OopsCore
import XCTest

/// Live words while a dictation streams: shown while the key is held, gone before the one write, and the text
/// written from the stream's finish. A WAV file stands in for the microphone; the engines are fakes.
@MainActor final class DictationSessionLiveTests: XCTestCase {
    func testAStreamingModelShowsWordsWhileRecordingAndWritesOnceAtTheEnd() async throws {
        let run = try DictationLiveRun(self)
        run.press(0)
        try await run.until { !run.shownWords.isEmpty }
        XCTAssertEqual(run.inserts.texts, [], "nothing is written while the key is held")
        XCTAssertEqual(run.drop.states, [.recording])
        run.release(1_200)
        try await run.until { run.drop.states.last == .left }
        XCTAssertEqual(run.drop.states, [.recording, .transcribing, .left])
        XCTAssertEqual(run.inserts.texts, ["Streamed text."])
        let opened = await run.engine.opened, transcribed = await run.engine.transcribed
        XCTAssertEqual(opened.count, 1)
        XCTAssertEqual(opened.first?.finished, 1)
        XCTAssertEqual(transcribed, 0, "the stream's finish gives the text")
    }

    func testWordsAreClearedBeforeTheOneWrite() async throws {
        let run = try DictationLiveRun(self)
        run.press(0)
        try await run.until { !run.shownWords.isEmpty }
        run.release(1_200)
        try await run.until { run.drop.states.last == .left }
        XCTAssertEqual(run.wordsAtInsert.count, 1)
        XCTAssertEqual(run.wordsAtInsert.first, .some(nil), "the words were taken away before the insert")
        XCTAssertEqual(run.drop.words.last, .some(nil))
    }

    func testAModelThatCannotStreamWritesItsOneShotTextWithoutWords() async throws {
        let run = try DictationLiveRun(self, engine: FakeStreamingEngine(streams: false))
        run.press(0)
        try await run.until { run.drop.states == [.recording] }
        run.release(1_200, audio: 1_600)
        try await run.until { run.drop.states.last == .left }
        XCTAssertEqual(run.inserts.texts, ["Hello"])
        XCTAssertEqual(run.shownWords, [])
        let transcribed = await run.engine.transcribed
        XCTAssertEqual(transcribed, 1)
    }

    func testEverySampleReachesTheStreamBeforeFinish() async throws {
        let audio = DictationSessionRun.speech()
        // Streamed while the key is held, then the rest at the release: the file from the press to its end, in order.
        let run = try DictationLiveRun(self, audio: audio)
        run.press(0)
        try await run.until { !run.shownWords.isEmpty }
        run.release(1_200)
        try await run.until { run.drop.states.last == .left }
        let streamed = await run.engine.opened.first?.samples ?? []
        XCTAssertGreaterThan(streamed.count, 40_000)
        XCTAssertTrue(streamed == Array(audio[6_400...].prefix(streamed.count)))
        XCTAssertEqual(run.inserts.texts, ["Streamed text."], "the stream heard no more than the clip")

        // A stream that opens only after the release hears the whole clip, through the release tail and no further.
        let late = FakeStreamingEngine()
        await late.holdStart()
        let held = try DictationLiveRun(self, engine: late, audio: audio)
        held.press(0)
        try await held.until { held.drop.states == [.recording] }
        held.release(1_200, audio: 1_600)
        try await held.until { held.drop.states == [.recording, .transcribing] }
        await late.proceed()
        try await held.until { held.drop.states.last == .left }
        let whole = await late.opened.first?.samples
        XCTAssertEqual(whole, Array(audio[6_400 ..< 28_800]))
        XCTAssertEqual(held.inserts.texts, ["Streamed text."])
    }

    func testAHostedEngineNeedsNoModelFileAndWritesItsTranscript() async throws {
        let hosted = FakeStreamingEngine(text: "Bonjour.")
        let run = try DictationLiveRun(self, hosted: hosted, modelPath: .some(nil))
        run.press(0)
        try await run.until { !run.shownWords.isEmpty }
        run.release(1_200)
        try await run.until { run.drop.states.last == .left }
        XCTAssertEqual(run.drop.states, [.recording, .transcribing, .left])
        XCTAssertEqual(run.inserts.texts, ["Bonjour."])
        let local = await (run.engine.opened.count, run.engine.loads, run.engine.transcribed), opened = await hosted.opened.count
        XCTAssertEqual(local.0, 0); XCTAssertEqual(local.1, 0); XCTAssertEqual(local.2, 0)
        XCTAssertEqual(opened, 1)
    }

    func testAHostedFailureEndsInTheFailedDropAndWritesNothing() async throws {
        let hosted = FakeStreamingEngine(error: .hostedFailed("timeout"))
        let run = try DictationLiveRun(self, hosted: hosted, modelPath: .some(nil))
        run.press(0)
        try await run.until { !run.shownWords.isEmpty }
        run.release(1_200)
        try await run.until { run.drop.states.count == 3 }
        XCTAssertEqual(run.drop.states, [.recording, .transcribing, .failed(.transcription)])
        XCTAssertEqual(run.inserts.texts, [])
        XCTAssertEqual(run.drop.words.last, .some(nil))
        let transcribed = await run.engine.transcribed
        XCTAssertEqual(transcribed, 0, "nothing else transcribes a hosted dictation")
    }

    func testEscapeCancelsTheStreamWithoutFinishing() async throws {
        let run = try DictationLiveRun(self)
        run.press(0)
        try await run.until { !run.shownWords.isEmpty }
        run.session.cancel()
        try await run.until { run.drop.states.last == .left }
        let streamOpened = await run.engine.opened.first
        let stream = try XCTUnwrap(streamOpened)
        try await run.until { stream.cancelled }
        XCTAssertEqual(stream.finished, 0)
        XCTAssertEqual(run.drop.words.last, .some(nil))
        XCTAssertEqual(run.inserts.texts, [])
    }

    func testSilenceCancelsTheStream() async throws {
        let quiet = (0 ..< 48_000).map { Float(0.000_7) * sin(2 * Float.pi * 220 * Float($0) / 16_000) }
        let hosted = FakeStreamingEngine()
        let run = try DictationLiveRun(self, hosted: hosted, audio: quiet)
        run.press(0)
        try await run.until { await hosted.opened.count == 1 }
        run.release(1_200)
        try await run.until { run.drop.states.last == .left }
        let streamOpened = await hosted.opened.first
        let stream = try XCTUnwrap(streamOpened)
        try await run.until { stream.cancelled }
        XCTAssertEqual(stream.finished, 0, "silence is never committed")
        XCTAssertEqual(run.inserts.texts, [])
    }

    func testANewRecordingDuringTranscriptionGetsItsOwnStream() async throws {
        let engine = FakeStreamingEngine()
        await engine.holdFinish()
        let run = try DictationLiveRun(self, engine: engine)
        run.press(0)
        try await run.until { !run.shownWords.isEmpty }
        run.release(1_200)
        let firstOpened = await engine.opened.first
        let first = try XCTUnwrap(firstOpened)
        try await run.until { first.finished == 1 }
        // Held while the first is still being transcribed: it records once that one is written.
        run.press(2_000)
        try await run.settle()
        first.proceed()
        try await run.until { await engine.opened.count == 2 }
        let secondOpened = await engine.opened.last
        let second = try XCTUnwrap(secondOpened)
        try await run.until { !second.samples.isEmpty }
        run.release(3_200)
        try await run.until { run.inserts.texts.count == 2 && run.drop.states.last == .left }
        XCTAssertFalse(first === second)
        XCTAssertEqual(second.finished, 1)
        XCTAssertEqual(run.inserts.texts, ["Streamed text.", "Streamed text."])
        XCTAssertEqual(run.wordsAtInsert, [nil, nil])
    }
}
