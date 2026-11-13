@testable import Oops
import OopsCore
import XCTest

/// A dictation's vocabulary, small cleanups and model cleanup, with a stub cleanup model, a fake engine, insert and
/// drop: no model, microphone, Accessibility or window.
@MainActor final class DictationSessionCleanupTests: XCTestCase {
    private func dictate(_ run: DictationSessionRun, at ms: Int64 = 0, cleanUp: Bool = false) async throws {
        run.press(ms, cleanUp: cleanUp)
        try await run.until { run.drop.states.last == .recording }
        run.release(ms + 1_200)
        try await run.until { [.left, .written].contains(run.drop.states.last) || run.drop.states.last.map(Self.failed) == true }
    }

    private static func failed(_ shown: FakeDictationDrop.Shown) -> Bool { if case .failed = shown { true } else { false } }

    private func cleanup(_ mode: DictationCleanupMode, _ model: CleanupStub?, small: SmallCleanups = .off,
                         vocabulary: VocabularyDelivery? = nil,
                         replace: @escaping @MainActor (String, String) async -> InsertReplacement = { _, _ in .replaced }) -> DictationSession.Cleanup {
        DictationSession.Cleanup(vocabulary: { vocabulary }, small: { small }, language: { "en" }, mode: { mode },
                                 backend: { if let model { return model }; throw CorrectionError.message("none") },
                                 timeout: .milliseconds(200), replace: replace)
    }

    func testOffMakesNoModelCallAndWritesTheTranscript() async throws {
        let model = CleanupStub(.answer("Cleaned."))
        let run = try DictationSessionRun(self, mode: .holdOnly, engine: FakeSpeechEngine(text: "um hello"), cleanup: cleanup(.off, model))
        try await dictate(run)
        XCTAssertEqual(run.inserts.texts, ["um hello"])
        XCTAssertEqual(run.drop.states, [.recording, .transcribing, .left])
        let calls = await model.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testAlwaysWritesTheCleanedText() async throws {
        let model = CleanupStub(.answer("Hello."))
        let run = try DictationSessionRun(self, mode: .holdOnly, engine: FakeSpeechEngine(text: "um hello"), cleanup: cleanup(.always, model))
        try await dictate(run)
        XCTAssertEqual(run.inserts.texts, ["Hello."])
        XCTAssertEqual(run.drop.states, [.recording, .transcribing, .cleaningUp, .left])
        let calls = await model.calls
        XCTAssertEqual(calls.map(\.instructions), [CleanupPrompt.instructions])
    }

    func testAProviderErrorATimeoutOrNoModelWritesTheRawTranscript() async throws {
        for model in [CleanupStub(.fail), CleanupStub(.slow), nil] {
            let run = try DictationSessionRun(self, mode: .holdOnly, engine: FakeSpeechEngine(text: "um hello"), cleanup: cleanup(.always, model))
            try await dictate(run)
            XCTAssertEqual(run.inserts.texts, ["um hello"])
            XCTAssertEqual(run.drop.states.last, .left)
        }
    }

    func testDictateAndCleanUpCleansWhateverTheSettingSays() async throws {
        let model = CleanupStub(.answer("Hello."))
        let run = try DictationSessionRun(self, mode: .holdOnly, engine: FakeSpeechEngine(text: "um hello"), cleanup: cleanup(.off, model))
        try await dictate(run, cleanUp: true)
        XCTAssertEqual(run.inserts.texts, ["Hello."])
        try await run.settle()
        try await dictate(run, at: 3_000)
        XCTAssertEqual(run.inserts.texts, ["Hello.", "um hello"])
    }

    func testTheModelCleansTheTextTheVocabularyAndSmallCleanupsLeft() async throws {
        let model = CleanupStub(.answer("Done."))
        let small = SmallCleanups(fillers: true, formatting: true, symbols: true)
        let run = try DictationSessionRun(self, mode: .holdOnly, engine: FakeSpeechEngine(text: "Um, tail scale comma new line"),
                                          cleanup: cleanup(.always, model, small: small, vocabulary: .fuzzyReplacement(["Tailscale"])))
        try await dictate(run)
        let calls = await model.calls
        XCTAssertEqual(calls.map(\.text), ["<transcript>\nTailscale,\n\n</transcript>"])
    }

    func testButtonOffersCleanUpAndPressingItReplacesTheInsertedText() async throws {
        let model = CleanupStub(.answer("Hello."))
        var replaced: [(String, String)] = []
        let run = try DictationSessionRun(self, mode: .holdOnly, engine: FakeSpeechEngine(text: "um hello"),
                                          cleanup: cleanup(.button, model) { replaced.append(($0, $1)); return .replaced })
        try await dictate(run)
        XCTAssertEqual(run.inserts.texts, ["um hello"])
        XCTAssertEqual(run.drop.states, [.recording, .transcribing, .written])
        let action = try XCTUnwrap(run.drop.action)
        XCTAssertEqual(action.label, "Clean up")
        var calls = await model.calls
        XCTAssertTrue(calls.isEmpty, "nothing is cleaned until the button is pressed")
        action.perform()
        try await run.until { run.drop.states.last == .left }
        XCTAssertEqual(run.drop.states, [.recording, .transcribing, .written, .cleaningUp, .left])
        XCTAssertEqual(replaced.map(\.0), ["um hello"])
        XCTAssertEqual(replaced.map(\.1), ["Hello."])
        calls = await model.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertFalse(run.session.holdsDrop)
    }

    func testButtonReplacesNothingWhenTheFieldChangedAndTheDropSaysSo() async throws {
        let run = try DictationSessionRun(self, mode: .holdOnly, engine: FakeSpeechEngine(text: "um hello"),
                                          cleanup: cleanup(.button, CleanupStub(.answer("Hello."))) { _, _ in .changed })
        try await dictate(run)
        try XCTUnwrap(run.drop.action).perform()
        try await run.until { run.drop.states.last == .failed(.textChanged) }
        XCTAssertEqual(DictationFailure.textChanged.message, "Text changed, nothing replaced")
    }

    func testButtonWithAFailingModelReplacesNothingAndSaysSo() async throws {
        var replaced = 0
        let run = try DictationSessionRun(self, mode: .holdOnly, engine: FakeSpeechEngine(text: "um hello"),
                                          cleanup: cleanup(.button, CleanupStub(.fail)) { _, _ in replaced += 1; return .replaced })
        try await dictate(run)
        try XCTUnwrap(run.drop.action).perform()
        try await run.until { run.drop.states.last == .failed(.cleanup) }
        XCTAssertEqual(replaced, 0)
    }

    func testButtonIsOfferedOnlyWhereTheFieldReadTheTextBack() async throws {
        let run = try DictationSessionRun(self, mode: .holdOnly, engine: FakeSpeechEngine(text: "um hello"),
                                          cleanup: cleanup(.button, CleanupStub(.answer("Hello."))))
        run.inserts.outcome = .unconfirmed
        try await dictate(run)
        XCTAssertEqual(run.drop.states, [.recording, .transcribing, .left])
        XCTAssertNil(run.drop.action)
    }

    func testTheEngineGetsOnlyItsOwnVocabularyAndAnEmptyOneSendsNothing() async throws {
        let bias = try XCTUnwrap(VocabularyBias.make([VocabularyEntry(term: "Tailscale")]))
        let deliveries: [VocabularyDelivery?] = [nil, .parakeetBias(bias), .prompt("Tailscale"), .fuzzyReplacement(["Tailscale"]),
                                                 .openAIKeywords(["Tailscale"])]
        for delivery in deliveries {
            let engine = FakeSpeechEngine(text: "hello")
            let run = try DictationSessionRun(self, mode: .holdOnly, engine: engine, cleanup: cleanup(.off, nil, vocabulary: delivery))
            try await dictate(run)
            let received = await engine.vocabularies
            switch delivery {
            case .parakeetBias?, .prompt?: XCTAssertEqual(received, [delivery])
            default: XCTAssertEqual(received, [nil], "\(String(describing: delivery))")
            }
        }
    }
}

/// A cleanup model that answers `text`, fails, or takes too long, and records each request.
private actor CleanupStub: CorrectionBackend {
    enum Behaviour: Sendable { case answer(String), fail, slow }
    private let behaviour: Behaviour
    private(set) var calls: [(text: String, instructions: String)] = []

    init(_ behaviour: Behaviour) { self.behaviour = behaviour }

    func complete(_ text: String, instructions: String) async throws -> String {
        calls.append((text, instructions))
        switch behaviour {
        case .answer(let answer): return String(decoding: try JSONSerialization.data(withJSONObject: ["text": answer]), as: UTF8.self)
        case .fail: throw CorrectionError.failure(.offline, "Stub failure.")
        case .slow:
            try await Task.sleep(for: .seconds(30))
            return #"{"text":"too late"}"#
        }
    }
}
