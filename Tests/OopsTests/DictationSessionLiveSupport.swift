import Foundation
@testable import Oops
import OopsCore
import Synchronization
import XCTest

/// A session as `DictationSessionRun` builds one, hold only, over a streaming engine and, when given, a hosted one:
/// a WAV file for the microphone, a fake insert and a fake drop.
@MainActor final class DictationLiveRun {
    let clock = ContinuousClock.now - .seconds(600)
    let drop = FakeDictationDrop()
    let inserts = FakeInsert()
    let source: ScriptedSource
    let recorder: DictationRecorder
    let engine: FakeStreamingEngine
    let hosted: any SpeechEngine?
    /// The words the drop showed last as each insert ran: nil once they were cleared.
    private(set) var wordsAtInsert: [LiveWords?] = []
    private(set) var session: DictationSession!

    init(_ test: XCTestCase, engine: FakeStreamingEngine = FakeStreamingEngine(), hosted: any SpeechEngine? = nil,
         modelPath: String?? = nil, audio: [Float] = DictationSessionRun.speech()) throws {
        self.engine = engine; self.hosted = hosted
        let url = try test.wavFile(float: audio, rate: 16_000)
        source = ScriptedSource(DictationAudioFile(url: url, pace: .immediate(from: DictationSessionRun.origin)))
        recorder = DictationRecorder(source: source, keepAliveSleep: { _ in try await Task.sleep(for: .seconds(3_600)) })
        let model = try modelPath ?? DictationSessionRun.modelFile(test), inserts = inserts, drop = drop
        session = DictationSession(recorder: recorder, engine: engine, hostedEngine: { hosted }, modelPath: { model },
                                   mode: { .holdOnly }, insert: { [weak self] text in
                                       self?.wordsAtInsert.append(drop.words.last ?? nil)
                                       return await inserts.insert(text)
                                   }, drop: drop, status: { _ in })
    }

    /// The words the drop showed, without the clearings.
    var shownWords: [String] { drop.words.compactMap { $0?.text } }

    /// As `DictationSessionRun`: key events at `ms` on the key clock and at `audio` on the file's timeline. The
    /// release defaults to the file's end, so the clip holds everything the stream heard.
    func press(_ ms: Int64, audio: Int64 = 400) {
        session.shortcut(.pressed, at: DictationSessionRun.origin + .milliseconds(audio), now: clock + .milliseconds(ms))
    }

    func release(_ ms: Int64, audio: Int64 = 3_000) {
        session.shortcut(.released, at: DictationSessionRun.origin + .milliseconds(audio), now: clock + .milliseconds(ms))
    }

    func until(seconds: Double = 3, _ condition: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while await !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("timed out", file: file, line: line) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func settle() async throws { try await Task.sleep(for: .milliseconds(150)) }
}

/// An engine whose streams show `w1`, `w2`… as audio is appended and finish with `text` or `error`; it refuses to
/// stream when `streams` is false, and transcribes once with `oneShot`. `holdStart()` keeps streams from opening
/// until `proceed()`.
actor FakeStreamingEngine: SpeechEngine {
    private let text: String, oneShot: String, error: SpeechEngineError?, streams: Bool
    private(set) var opened: [FakeSpeechStream] = []
    private(set) var loads = 0, transcribed = 0
    private var held = false, waiting: [CheckedContinuation<Void, Never>] = []
    /// The next stream's finish waits until that stream's `proceed()`.
    private var holdsFinish = false

    init(text: String = "Streamed text.", oneShot: String = "Hello", error: SpeechEngineError? = nil, streams: Bool = true) {
        self.text = text; self.oneShot = oneShot; self.error = error; self.streams = streams
    }

    func holdStart() { held = true }
    func holdFinish() { holdsFinish = true }
    func proceed() {
        held = false
        waiting.forEach { $0.resume() }
        waiting = []
    }

    func load(model url: URL) async throws { loads += 1 }
    func warmUp(model url: URL) async throws { loads += 1 }
    func unload() async {}

    func transcribe(_ samples: [Float], language: String?, vocabulary: VocabularyDelivery?) async throws -> String {
        transcribed += 1
        return oneShot
    }

    func startStream(language: String?, vocabulary: VocabularyDelivery?) async throws -> any SpeechStream {
        if held { await withCheckedContinuation { waiting.append($0) } }
        guard streams else { throw SpeechEngineError.streamingUnsupported }
        let stream = FakeSpeechStream(text: text, error: error, holdsFinish: holdsFinish)
        holdsFinish = false
        opened.append(stream)
        return stream
    }
}

/// One fake dictation stream: every sample appended in order, `w<n>` after the n-th append, and how it ended.
final class FakeSpeechStream: SpeechStream {
    let words: AsyncStream<LiveWords>
    private let continuation: AsyncStream<LiveWords>.Continuation
    private let text: String, error: SpeechEngineError?
    private let state: Mutex<(samples: [Float], appends: Int, finished: Int, cancelled: Bool, held: Bool, gate: CheckedContinuation<Void, Never>?)>

    init(text: String, error: SpeechEngineError?, holdsFinish: Bool) {
        (words, continuation) = AsyncStream.makeStream(of: LiveWords.self)
        self.text = text; self.error = error
        state = Mutex(([], 0, 0, false, holdsFinish, nil))
    }

    var samples: [Float] { state.withLock { $0.samples } }
    var finished: Int { state.withLock { $0.finished } }
    var cancelled: Bool { state.withLock { $0.cancelled } }

    func append(_ samples: [Float]) async {
        let count = state.withLock { state -> Int? in
            guard state.finished == 0, !state.cancelled else { return nil }
            state.samples += samples
            state.appends += 1
            return state.appends
        }
        if let count { continuation.yield(LiveWords(stable: "w\(count)")) }
    }

    func finish() async throws -> String {
        state.withLock { $0.finished += 1 }
        await withCheckedContinuation { gate in
            let open = state.withLock { state in
                if state.held { state.gate = gate }
                return !state.held
            }
            if open { gate.resume() }
        }
        continuation.finish()
        if let error { throw error }
        return text
    }

    /// Lets a held `finish` return.
    func proceed() {
        state.withLock { state in
            defer { state.held = false; state.gate = nil }
            return state.gate
        }?.resume()
    }

    func cancel() async {
        state.withLock { $0.cancelled = true }
        continuation.finish()
    }
}
