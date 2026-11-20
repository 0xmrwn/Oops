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
                         vocabulary: VocabularyDelivery? = nil, intact: Bool = false, shortcut: String? = nil,
                         replace: @escaping @MainActor (String, String) async -> InsertReplacement = { _, _ in .replaced }) -> DictationSession.Cleanup {
        DictationSession.Cleanup(vocabulary: { vocabulary }, small: { small }, language: { "en" }, mode: { mode },
                                 available: { model != nil }, backend: { if let model { return model }; throw CorrectionError.message("none") },
                                 timeout: .milliseconds(200), replace: replace, intact: { _ in intact }, shortcutLabel: { shortcut })
    }

    func testOffMakesNoModelCallAndWritesTheTranscriptAsHeard() async throws {
        let model = CleanupStub(.answer("Cleaned."))
        let small = SmallCleanups(fillers: true, formatting: true, symbols: true)
        let run = try DictationSessionRun(self, mode: .holdOnly, engine: FakeSpeechEngine(text: "um hello comma"),
                                          cleanup: cleanup(.off, model, small: small))
        try await dictate(run)
        XCTAssertEqual(run.inserts.texts, ["um hello comma"], "Off runs none of the small cleanups, even switched on")
        XCTAssertEqual(run.drop.states, [.recording, .transcribing, .written])
        let calls = await model.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testBasicRunsTheSmallCleanupsWithoutTheModel() async throws {
        let model = CleanupStub(.answer("Cleaned."))
        let small = SmallCleanups(fillers: true, formatting: true, symbols: true)
        let run = try DictationSessionRun(self, mode: .holdOnly, engine: FakeSpeechEngine(text: "um hello comma"),
                                          cleanup: cleanup(.basic, model, small: small))
        try await dictate(run)
        XCTAssertEqual(run.inserts.texts.count, 1)
        XCTAssertNotEqual(run.inserts.texts.first, "um hello comma")
        let calls = await model.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testAIWritesTheCleanedText() async throws {
        let model = CleanupStub(.answer("Hello."))
        let run = try DictationSessionRun(self, mode: .holdOnly, engine: FakeSpeechEngine(text: "um hello"), cleanup: cleanup(.ai, model))
        try await dictate(run)
        XCTAssertEqual(run.inserts.texts, ["Hello."])
        XCTAssertEqual(run.drop.states, [.recording, .transcribing, .cleaningUp, .left])
        let calls = await model.calls
        XCTAssertEqual(calls.map(\.instructions), [CleanupPrompt.instructions])
    }

    func testAProviderErrorATimeoutOrNoModelWritesTheBasicTextAndSaysSo() async throws {
        for model in [CleanupStub(.fail), CleanupStub(.slow), nil] {
            let run = try DictationSessionRun(self, mode: .holdOnly, engine: FakeSpeechEngine(text: "um hello"), cleanup: cleanup(.ai, model))
            try await dictate(run)
            XCTAssertEqual(run.inserts.texts, ["um hello"])
            XCTAssertEqual(run.drop.states.last, .failed(.cleanup))
            XCTAssertNil(run.drop.action, "no button offers the cleanup that just failed")
        }
    }

    func testCleanUpWithAIDictatesCleanedWhateverTheLevelSays() async throws {
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
                                          cleanup: cleanup(.ai, model, small: small, vocabulary: .fuzzyReplacement(["Tailscale"])))
        try await dictate(run)
        let calls = await model.calls
        XCTAssertEqual(calls.map(\.text), ["<transcript>\nTailscale,\n\n</transcript>"])
    }

    func testBasicOffersCleanUpAndPressingItReplacesTheInsertedText() async throws {
        let model = CleanupStub(.answer("Hello."))
        var replaced: [(String, String)] = []
        let run = try DictationSessionRun(self, mode: .holdOnly, engine: FakeSpeechEngine(text: "um hello"),
                                          cleanup: cleanup(.basic, model, shortcut: "⌃⌘E") { replaced.append(($0, $1)); return .replaced })
        try await dictate(run)
        XCTAssertEqual(run.inserts.texts, ["um hello"])
        XCTAssertEqual(run.drop.states, [.recording, .transcribing, .written])
        let action = try XCTUnwrap(run.drop.action)
        XCTAssertEqual(action.label, "Clean up with AI · ⌃⌘E")
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

    func testACleanupOvertakenByANewDictationReplacesNothing() async throws {
        var replaced = 0
        let run = try DictationSessionRun(self, mode: .holdOnly, engine: FakeSpeechEngine(text: "um hello"),
                                          cleanup: cleanup(.basic, CleanupStub(.late("Hello."))) { _, _ in replaced += 1; return .replaced })
        try await dictate(run)
        try XCTUnwrap(run.drop.action).perform()
        run.press(3_000)
        try await run.until { run.drop.states.last == .recording }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(replaced, 0, "the answer came after the next dictation began")
        XCTAssertEqual(run.session.lastTranscript, "um hello")
        XCTAssertEqual(run.drop.states.last, .recording, "and the new recording keeps the drop")
    }

    func testButtonReplacesNothingWhenTheFieldChangedAndTheDropSaysSo() async throws {
        let run = try DictationSessionRun(self, mode: .holdOnly, engine: FakeSpeechEngine(text: "um hello"),
                                          cleanup: cleanup(.basic, CleanupStub(.answer("Hello."))) { _, _ in .changed })
        try await dictate(run)
        try XCTUnwrap(run.drop.action).perform()
        try await run.until { run.drop.states.last == .failed(.textChanged) }
        XCTAssertEqual(DictationFailure.textChanged.message, "Text changed, nothing replaced")
    }

    func testButtonWithAFailingModelReplacesNothingAndSaysSo() async throws {
        var replaced = 0
        let run = try DictationSessionRun(self, mode: .holdOnly, engine: FakeSpeechEngine(text: "um hello"),
                                          cleanup: cleanup(.basic, CleanupStub(.fail)) { _, _ in replaced += 1; return .replaced })
        try await dictate(run)
        try XCTUnwrap(run.drop.action).perform()
        try await run.until { run.drop.states.last == .failed(.cleanup) }
        XCTAssertEqual(replaced, 0)
    }

    func testButtonIsOfferedOnlyWhereTheFieldReadTheTextBackAndWithAModel() async throws {
        let run = try DictationSessionRun(self, mode: .holdOnly, engine: FakeSpeechEngine(text: "um hello"),
                                          cleanup: cleanup(.basic, CleanupStub(.answer("Hello."))))
        run.inserts.outcome = .unconfirmed
        try await dictate(run)
        XCTAssertEqual(run.drop.states, [.recording, .transcribing, .left])
        XCTAssertNil(run.drop.action)
        let none = try DictationSessionRun(self, mode: .holdOnly, engine: FakeSpeechEngine(text: "um hello"), cleanup: cleanup(.basic, nil))
        try await dictate(none)
        XCTAssertEqual(none.drop.states, [.recording, .transcribing, .left])
    }

    func testTheShortcutCleansTheLastDictationWhileItIsIntact() async throws {
        let model = CleanupStub(.answer("Hello."))
        var replaced: [(String, String)] = []
        let run = try DictationSessionRun(self, mode: .holdOnly, engine: FakeSpeechEngine(text: "um hello"),
                                          cleanup: cleanup(.basic, model, intact: true) { replaced.append(($0, $1)); return .replaced })
        try await dictate(run)
        run.press(3_000, cleanUp: true)
        try await run.until { run.drop.states.last == .left }
        run.release(3_100)
        try await run.settle()
        XCTAssertEqual(run.drop.states, [.recording, .transcribing, .written, .cleaningUp, .left], "nothing recorded")
        XCTAssertEqual(replaced.map(\.0), ["um hello"])
        XCTAssertEqual(replaced.map(\.1), ["Hello."])
        XCTAssertEqual(run.inserts.texts, ["um hello"])
    }

    func testTheShortcutDictatesWhenTheLastDictationIsNoLongerIntact() async throws {
        let model = CleanupStub(.answer("Hello."))
        var replaced = 0
        let run = try DictationSessionRun(self, mode: .holdOnly, engine: FakeSpeechEngine(text: "um hello"),
                                          cleanup: cleanup(.basic, model, intact: false) { _, _ in replaced += 1; return .replaced })
        try await dictate(run)
        try await dictate(run, at: 3_000, cleanUp: true)
        XCTAssertEqual(run.inserts.texts, ["um hello", "Hello."])
        XCTAssertEqual(replaced, 0)
    }

    func testTheShortcutDictatesWhenTheLastDictationWasOnlyKept() async throws {
        let run = try DictationSessionRun(self, mode: .holdOnly, engine: FakeSpeechEngine(text: "um hello"),
                                          cleanup: cleanup(.basic, CleanupStub(.answer("Hello.")), intact: true))
        run.inserts.outcome = .refused(.noEditor)
        run.press(0)
        try await run.until { run.drop.states.last == .recording }
        run.release(1_200)
        try await run.until { run.drop.states.last == .kept }
        run.inserts.outcome = .inserted
        try await dictate(run, at: 3_000, cleanUp: true)
        XCTAssertEqual(run.inserts.texts, ["um hello", "Hello."])
    }

    func testOfferingTheButtonBuildsNoBackendUntilItIsPressed() async throws {
        var built = 0
        let model = CleanupStub(.answer("Hello."))
        var plan = cleanup(.basic, model)
        plan.backend = { built += 1; return model }
        let run = try DictationSessionRun(self, mode: .holdOnly, engine: FakeSpeechEngine(text: "um hello"), cleanup: plan)
        try await dictate(run)
        XCTAssertNotNil(run.drop.action)
        XCTAssertEqual(built, 0, "offering reads only whether a model is chosen")
        try XCTUnwrap(run.drop.action).perform()
        try await run.until { run.drop.states.last == .left }
        XCTAssertEqual(built, 1)
    }

    func testTheShortcutWhileFixHoldsTheDropSaysSoAndRecordsNothing() async throws {
        let model = CleanupStub(.answer("Hello."))
        let run = try DictationSessionRun(self, mode: .holdOnly, engine: FakeSpeechEngine(text: "um hello"),
                                          cleanup: cleanup(.basic, model, intact: true))
        try await dictate(run)
        run.drop.available = false
        run.press(3_000, cleanUp: true)
        try await run.until { !run.status.isEmpty }
        run.release(3_100)
        try await run.settle()
        XCTAssertEqual(run.status, [CorrectionSession.dropTaken])
        XCTAssertEqual(run.drop.states, [.recording, .transcribing, .written], "nothing cleaned, nothing recorded")
        let calls = await model.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testTheSavedChoiceMovesToTheLevelsOnce() throws {
        let suite = "DictationSessionCleanupTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let key = DictationCleanupMode.key
        for (saved, small, level) in [("always", false, "ai"), ("button", true, "basic"), ("off", true, "basic"),
                                      ("button", false, "off"), ("off", false, "off"), ("ai", false, "ai"), ("basic", false, "basic")] {
            defaults.removeObject(forKey: DictationCleanupMode.levelsKey)
            defaults.set(saved, forKey: key)
            defaults.set(small, forKey: SmallCleanups.symbolsKey)
            DictationCleanupMode.migrate(defaults)
            XCTAssertEqual(defaults.string(forKey: key), level, "\(saved) small=\(small)")
        }
        defaults.set("off", forKey: key)
        defaults.set(true, forKey: SmallCleanups.symbolsKey)
        DictationCleanupMode.migrate(defaults)
        XCTAssertEqual(defaults.string(forKey: key), "off", "once only: Off chosen since stays")
        defaults.removeObject(forKey: DictationCleanupMode.levelsKey)
        defaults.removeObject(forKey: key)
        defaults.set(false, forKey: SmallCleanups.symbolsKey)
        DictationCleanupMode.migrate(defaults)
        XCTAssertNil(defaults.string(forKey: key), "nothing saved and nothing on stays unsaved")
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
    enum Behaviour: Sendable { case answer(String), late(String), fail, slow }
    private let behaviour: Behaviour
    private(set) var calls: [(text: String, instructions: String)] = []

    init(_ behaviour: Behaviour) { self.behaviour = behaviour }

    func complete(_ text: String, instructions: String, deadline: Duration) async throws -> String {
        calls.append((text, instructions))
        switch behaviour {
        case .answer(let answer): return String(decoding: try JSONSerialization.data(withJSONObject: ["text": answer]), as: UTF8.self)
        case .late(let answer):
            try await Task.sleep(for: .milliseconds(120))
            return String(decoding: try JSONSerialization.data(withJSONObject: ["text": answer]), as: UTF8.self)
        case .fail: throw CorrectionError.failure(.offline, "Stub failure.")
        case .slow:
            try await Task.sleep(for: .seconds(30))
            return #"{"text":"too late"}"#
        }
    }
}
