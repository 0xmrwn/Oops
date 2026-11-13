import XCTest
@testable import OopsCore

/// Dictation's model cleanup with a stub provider: no model is called.
final class CleanupPromptTests: XCTestCase {
    func testTheRequestCarriesTheCleanupPromptAndTheTranscriptAsDelimitedData() async {
        let backend = CleanupStub(.answer("Hello, there."))
        let cleaned = await CleanupPrompt.clean("um hello there", with: backend)
        XCTAssertEqual(cleaned, "Hello, there.")
        let calls = await backend.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].text, "<transcript>\num hello there\n</transcript>")
        XCTAssertEqual(calls[0].instructions, CleanupPrompt.instructions)
        XCTAssertFalse(calls[0].instructions.contains(CorrectionPolicy.defaultRules))
        XCTAssertFalse(calls[0].instructions.contains(CorrectionPolicy.contract))
        XCTAssertNotEqual(calls[0].instructions, CorrectionPolicy.instructions)
    }

    func testThePromptAlsoAsksForTheSmallCleanups() {
        for asked in ["filler words", "new line", "à la ligne", "nouveau paragraphe", "quotation marks", "comma", "hashtag", "underscore"] {
            XCTAssertTrue(CleanupPrompt.instructions.contains(asked), asked)
        }
    }

    func testAProviderErrorOrATimeoutGivesNothingSoTheTranscriptIsWrittenAsHeard() async {
        let failing = CleanupStub(.fail)
        let failed = await CleanupPrompt.clean("hello", with: failing)
        XCTAssertNil(failed)
        let slow = CleanupStub(.slow)
        let started = ContinuousClock.now
        let timedOut = await CleanupPrompt.clean("hello", with: slow, timeout: .milliseconds(100))
        XCTAssertNil(timedOut)
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(5))
    }

    func testABlankOrTooLongTranscriptMakesNoCall() async {
        let backend = CleanupStub(.answer("x"))
        for transcript in ["", "  \n", String(repeating: "a", count: CleanupPrompt.maximumLength + 1)] {
            let cleaned = await CleanupPrompt.clean(transcript, with: backend)
            XCTAssertNil(cleaned)
        }
        let calls = await backend.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testDecodingKeepsOnlyAUsableText() {
        XCTAssertEqual(CleanupPrompt.decode(#"{"text":"  Hi.\n"}"#), "Hi.")
        XCTAssertEqual(CleanupPrompt.decode(#"{"text":"<transcript>\nHi.\n</transcript>"}"#), "Hi.")
        XCTAssertEqual(CleanupPrompt.decode("{\"text\":\"H\u{200B}i\u{FEFF}.\"}"), "Hi.")
        XCTAssertEqual(CleanupPrompt.decode(#"{"text":"Line one\nLine two"}"#), "Line one\nLine two")
        for raw in [#"{"text":"   "}"#, #"{"text":""}"#, "not json", #"{"other":"x"}"#, #"{"text":3}"#, ""] {
            XCTAssertNil(CleanupPrompt.decode(raw), raw)
        }
    }
}

/// A cleanup model that answers `text`, fails, or takes too long, and records each request.
actor CleanupStub: CorrectionBackend {
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
