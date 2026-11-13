@testable import Oops
import OopsCore
import Synchronization
import XCTest

/// A dictation from the shortcut to the insert, with a WAV file for the microphone, a fake engine, a fake
/// insert and a fake drop: no microphone, Accessibility, model or window.
@MainActor final class DictationSessionTests: XCTestCase {
    func testAHoldInsertsTheTranscriptOnceAndTheDropLeaves() async throws {
        let run = try DictationSessionRun(self, mode: .holdOnly, engine: FakeSpeechEngine(text: "  Hello there. \n"))
        run.press(0)
        try await run.until { run.drop.states == [.recording] }
        run.release(1_200)
        try await run.until { run.drop.states.last == .left }
        XCTAssertEqual(run.drop.states, [.recording, .transcribing, .left])
        XCTAssertEqual(run.inserts.texts, ["Hello there."])
        let transcribed = await run.engine?.transcribed
        XCTAssertEqual(transcribed, 1)
        XCTAssertFalse(run.session.holdsDrop)
    }

    func testTheChosenLanguageReachesTheEngine() async throws {
        let run = try DictationSessionRun(self, mode: .holdOnly, language: "fr")
        run.press(0)
        try await run.until { run.drop.states == [.recording] }
        run.release(1_200)
        try await run.until { run.drop.states.last == .left }
        let languages = await run.engine?.languages
        XCTAssertEqual(languages, ["fr"])
    }

    func testSilenceWritesNothingAndNeverCallsTheEngine() async throws {
        let quiet = (0 ..< 48_000).map { Float(0.000_7) * sin(2 * Float.pi * 220 * Float($0) / 16_000) }
        let run = try DictationSessionRun(self, mode: .holdOnly, audio: quiet)
        run.press(0)
        run.release(1_200)
        try await run.until { run.drop.states.last == .left }
        XCTAssertEqual(run.drop.states, [.recording, .transcribing, .left])
        XCTAssertEqual(run.inserts.texts, [])
        let transcribed = await run.engine?.transcribed
        XCTAssertEqual(transcribed, 0)
    }

    func testNoModelPathOrNoFileThereShowsNoSpeechModelWithoutOpeningTheSource() async throws {
        for path in [nil, "~/no-such-oops-model-\(UUID().uuidString).bin"] {
            let run = try DictationSessionRun(self, mode: .holdOnly, modelPath: .some(path))
            run.press(0)
            try await run.until { !run.drop.states.isEmpty }
            run.release(1_200)
            try await run.settle()
            XCTAssertEqual(run.drop.states, [.failed(.noModel)], "\(path ?? "no path")")
            XCTAssertEqual(run.source.opens, 0)
            XCTAssertFalse(run.session.holdsDrop)
        }
    }

    func testABuildWithoutTheEngineSaysSoAndOpensNothing() async throws {
        let run = try DictationSessionRun(self, mode: .holdOnly, engine: nil)
        run.press(0)
        run.release(1_200)
        try await run.until { !run.drop.states.isEmpty }
        try await run.settle()
        XCTAssertEqual(run.drop.states, [.failed(.notInBuild)])
        XCTAssertEqual(run.source.opens, 0)
    }

    func testMicrophoneAccessRefusedSaysSoAndTheNextPressStartsAgain() async throws {
        let run = try DictationSessionRun(self, mode: .holdOnly)
        run.source.refuse(.microphoneAccess(.denied))
        run.press(0)
        run.release(1_200)
        try await run.until { run.drop.states == [.failed(.microphoneAccess)] }
        try await run.settle()
        run.press(3_000)
        run.release(4_200)
        try await run.until { run.drop.states.last == .left }
        XCTAssertEqual(run.drop.states, [.failed(.microphoneAccess), .recording, .transcribing, .left])
        XCTAssertEqual(run.inserts.texts, ["Hello"])
    }

    func testAPressWithTheMicrophoneNeverAskedAsksOnceRecordsNothingAndSaysToPressAgain() async throws {
        let run = try DictationSessionRun(self, mode: .holdOnly)
        run.source.refuse(.microphoneAccess(.undetermined))
        run.press(0)
        try await run.until { run.asks == 1 }
        // A second press while the prompt is up asks nothing more.
        run.source.refuse(.microphoneAccess(.undetermined))
        run.press(500)
        run.release(700)
        try await run.settle()
        XCTAssertEqual(run.asks, 1)
        XCTAssertEqual(run.drop.states, [.left, .left])
        run.answer(true)
        try await run.until { run.drop.states.last == .ready }
        XCTAssertEqual(run.source.opens, 0)
        XCTAssertEqual(run.inserts.texts, [])
        XCTAssertFalse(run.session.holdsDrop)
        run.press(3_000)
        run.release(4_200)
        try await run.until { run.drop.states.last == .left && run.inserts.texts == ["Hello"] }
        XCTAssertEqual(run.drop.states, [.left, .left, .ready, .recording, .transcribing, .left])
    }

    func testTheMicrophoneRefusedAtThePromptSaysAccessIsOff() async throws {
        let run = try DictationSessionRun(self, mode: .holdOnly)
        run.source.refuse(.microphoneAccess(.undetermined))
        run.press(0)
        run.release(1_200)
        try await run.until { run.asks == 1 }
        run.answer(false)
        try await run.until { run.drop.states.last == .failed(.microphoneAccess) }
        XCTAssertEqual(run.drop.states, [.left, .failed(.microphoneAccess)])
        XCTAssertEqual(run.source.opens, 0)
    }

    func testADropHeldByAnotherFeatureStartsNothing() async throws {
        let run = try DictationSessionRun(self, mode: .holdOnly)
        run.drop.available = false
        run.press(0)
        run.release(1_200)
        try await run.until { !run.status.isEmpty }
        try await run.settle()
        XCTAssertEqual(run.status, [CorrectionSession.dropTaken])
        XCTAssertEqual(run.drop.states, [])
        XCTAssertEqual(run.source.opens, 0)
        XCTAssertFalse(run.session.holdsDrop)
    }

    func testARefusedInsertSaysItCantWriteHere() async throws {
        let run = try DictationSessionRun(self, mode: .holdOnly)
        run.inserts.outcome = .refused(.secureField)
        run.press(0)
        run.release(1_200)
        try await run.until { run.drop.states.count == 3 }
        XCTAssertEqual(run.drop.states, [.recording, .transcribing, .failed(.cannotWrite)])
    }

    func testACancelledInsertSaysNothing() async throws {
        let run = try DictationSessionRun(self, mode: .holdOnly)
        run.inserts.outcome = .refused(.cancelled)
        run.press(0)
        run.release(1_200)
        try await run.until { run.drop.states.count == 3 }
        XCTAssertEqual(run.drop.states, [.recording, .transcribing, .left])
    }

    func testAnEngineErrorSaysItCouldntTranscribe() async throws {
        let engine = FakeSpeechEngine(text: "Hello")
        await engine.fail(with: .transcriptionFailed("broken"))
        let run = try DictationSessionRun(self, mode: .holdOnly, engine: engine)
        run.press(0)
        run.release(1_200)
        try await run.until { run.drop.states.count == 3 }
        XCTAssertEqual(run.drop.states, [.recording, .transcribing, .failed(.transcription)])
        XCTAssertEqual(run.inserts.texts, [])
    }

    func testAReleaseDuringASlowStartIsStillHonoured() async throws {
        let run = try DictationSessionRun(self, mode: .holdOnly)
        run.source.openDelay = 0.4
        run.press(0)
        run.release(1_200)
        try await run.until(seconds: 5) { run.drop.states.last == .left }
        XCTAssertEqual(run.drop.states, [.recording, .transcribing, .left])
        XCTAssertEqual(run.inserts.texts, ["Hello"])
    }

    func testTheModelIsAFileAtThePath() throws {
        XCTAssertNil(DictationSession.modelURL(nil))
        XCTAssertNil(DictationSession.modelURL(""))
        XCTAssertNil(DictationSession.modelURL("~"), "the home folder, once expanded, is no model")
        let model = try DictationSessionRun.modelFile(self)
        XCTAssertEqual(DictationSession.modelURL(model)?.path, model)
    }
}

// MARK: - Support

/// One session over fakes. Key events are placed on a synthetic key clock that lies in the past, so the
/// activation's timers fire at once, and on the audio file's timeline, which starts at `origin`.
@MainActor final class DictationSessionRun {
    static let origin = CaptureInstant(nanoseconds: 60_000_000_000)
    let clock = ContinuousClock.now - .seconds(600)
    let drop = FakeDictationDrop()
    let inserts = FakeInsert()
    let source: ScriptedSource
    let engine: FakeSpeechEngine?
    var mode: DictationMode
    var status: [String] = []
    /// How often the session asked for the microphone, and the prompt it is waiting on.
    private(set) var asks = 0
    private var prompt: CheckedContinuation<Bool, Never>?
    private(set) var session: DictationSession!

    init(_ test: XCTestCase, mode: DictationMode, audio: [Float]? = nil, engine: FakeSpeechEngine? = FakeSpeechEngine(text: "Hello"),
         modelPath: String?? = nil, language: String? = nil) throws {
        self.mode = mode
        self.engine = engine
        let url = try test.wavFile(float: audio ?? Self.speech(), rate: 16_000)
        source = ScriptedSource(DictationAudioFile(url: url, pace: .immediate(from: Self.origin)))
        let recorder = DictationRecorder(source: source, keepAliveSleep: { _ in try await Task.sleep(for: .seconds(3_600)) })
        let path = try modelPath ?? Self.modelFile(test)
        let inserts = inserts
        session = DictationSession(recorder: recorder, engine: engine, modelPath: { path }, language: { language },
                                   mode: { [weak self] in self?.mode ?? .holdOrTap },
                                   insert: { await inserts.insert($0) }, drop: drop, status: { [weak self] in self?.status.append($0) },
                                   askMicrophone: { [weak self] in
                                       await withCheckedContinuation { self?.asks += 1; self?.prompt = $0 }
                                   })
    }

    /// Answers the microphone prompt the session is waiting on.
    func answer(_ granted: Bool) {
        prompt?.resume(returning: granted)
        prompt = nil
    }

    /// Key events at `ms` on the key clock and at `audio` on the file's timeline: by default a press at
    /// 400 ms and a release at 1.6 s, around the speech, since the file plays from the start each time it opens.
    func press(_ ms: Int64, audio: Int64? = nil) {
        session.shortcut(.pressed, at: Self.origin + .milliseconds(audio ?? 400), now: clock + .milliseconds(ms))
    }

    func release(_ ms: Int64, audio: Int64? = nil) {
        session.shortcut(.released, at: Self.origin + .milliseconds(audio ?? 1_600), now: clock + .milliseconds(ms))
    }

    func until(seconds: Double = 3, _ condition: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while await !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("timed out", file: file, line: line) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Lets queued events and any work they started run out.
    func settle() async throws { try await Task.sleep(for: .milliseconds(150)) }

    /// 0.5 s of silence, 1 s of a 180 Hz voice at -13 dBFS, then 1.5 s of silence.
    static func speech() -> [Float] {
        (0 ..< 48_000).map { index in
            let seconds = Double(index) / 16_000
            return (0.5 ..< 1.5).contains(seconds) ? 0.3 * Float(sin(2 * Double.pi * 180 * seconds)) : 0
        }
    }

    /// An empty file standing in for a model: the fake engine never reads it.
    static func modelFile(_ test: XCTestCase) throws -> String {
        let url = FileManager.default.temporaryDirectory.appending(path: "dictation-model-\(UUID().uuidString).bin")
        try Data([0]).write(to: url)
        test.addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url.path
    }
}

/// The drop's states in order, `.left` for each time it left.
@MainActor final class FakeDictationDrop: DictationDrop {
    enum Shown: Equatable {
        case recording, transcribing, ready, failed(DictationFailure), left
    }

    var available = true
    private(set) var states: [Shown] = []
    var journal: ((String) -> Void)?

    func claim(busy: @escaping () -> Bool) -> Bool { available }

    func show(_ state: DictationDropState) {
        switch state {
        case .recording: states.append(.recording)
        case .transcribing: states.append(.transcribing)
        case .ready: states.append(.ready)
        case .failed(let failure): states.append(.failed(failure))
        }
        journal?("\(state)")
    }

    func leave() {
        states.append(.left)
        journal?("left")
    }
}

@MainActor final class FakeInsert {
    var outcome = InsertOutcome.inserted
    private(set) var texts: [String] = []
    var journal: ((String) -> Void)?

    func insert(_ text: String) async -> InsertOutcome {
        texts.append(text)
        journal?("insert \(text)")
        return outcome
    }
}

/// Answers every transcription with `text`, or with an error; `hold()` keeps transcriptions waiting until
/// `proceed()`.
actor FakeSpeechEngine: SpeechEngine {
    private let text: String
    private var error: SpeechEngineError?
    private(set) var transcribed = 0
    private(set) var loads: [URL] = []
    private(set) var languages: [String?] = []
    private var held = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(text: String) { self.text = text }

    func fail(with error: SpeechEngineError) { self.error = error }
    func hold() { held = true }

    func proceed() {
        held = false
        waiting.forEach { $0.resume() }
        waiting = []
    }

    func load(model url: URL) async throws { loads.append(url) }
    func warmUp(model url: URL) async throws { loads.append(url) }

    func transcribe(_ samples: [Float], language: String?) async throws -> String {
        transcribed += 1
        languages.append(language)
        if held { await withCheckedContinuation { waiting.append($0) } }
        if let error { throw error }
        return text
    }

    func unload() async {}
}

/// A file standing in for the microphone that can be slow to open or refuse to, and counts its opens.
final class ScriptedSource: DictationAudioSource {
    private let inner: any DictationAudioSource
    private let state = Mutex((opens: 0, delay: 0.0, refusal: DictationAudioError?.none))

    init(_ inner: any DictationAudioSource) { self.inner = inner }

    var opens: Int { state.withLock { $0.opens } }

    var openDelay: Double {
        get { state.withLock { $0.delay } }
        set { state.withLock { $0.delay = newValue } }
    }

    /// The next open fails with `error`.
    func refuse(_ error: DictationAudioError) { state.withLock { $0.refusal = error } }

    func open(into ring: DictationAudioRing) throws(DictationAudioError) -> Double {
        let (delay, refusal) = state.withLock { state in
            defer { state.refusal = nil }
            return (state.delay, state.refusal)
        }
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        if let refusal { throw refusal }
        state.withLock { $0.opens += 1 }
        return try inner.open(into: ring)
    }

    func close() { inner.close() }
}
