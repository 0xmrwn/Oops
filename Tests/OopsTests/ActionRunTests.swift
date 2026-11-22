import ApplicationServices
import Foundation
@testable import Oops
import OopsCore
import Testing

/// What an action sends, how a run ends, and the words it fails in.
struct ActionRunTests {
    @Test func `the action's own prompt is sent, not Fix's`() async throws {
        let backend = Recording(reply: #"{"text":"hi"}"#)
        let request = ActionPrompt.request(for: .typed("Shorten it"), draft: "hello")
        let answer = try await ActionSession.answer(request, draft: "hello", from: backend, deadline: .seconds(5))
        let sent = await backend.sent
        #expect(answer == "hi")
        #expect(sent?.instructions == request.instructions)
        #expect(sent?.instructions.contains(ActionPrompt.rules) == true)
        #expect(sent?.instructions.contains(CorrectionPolicy.defaultRules) == false)
        #expect(sent?.text == "<draft>\nhello\n</draft>")
    }

    @Test func `a run ends at its deadline as a failure`() async {
        let backend = Recording(reply: #"{"text":"late"}"#, delay: .seconds(5))
        let started = ContinuousClock.now
        await #expect(throws: ActionFailure.slow) {
            try await ActionSession.answer(ActionPrompt.request(for: .typed("x"), draft: "y"), draft: "y", from: backend, deadline: .milliseconds(100))
        }
        #expect(started.duration(to: .now) < .seconds(1))
    }

    @Test @MainActor func `the deadline is Fix's`() {
        #expect(ActionSession.deadline == Recording.defaultDeadline)
        #expect(ActionSession.deadline == .seconds(40))
    }

    @Test func `an unusable answer is a failure`() async {
        let backend = Recording(reply: "not json")
        var thrown: Error?
        do { _ = try await ActionSession.answer(ActionPrompt.request(for: .typed("x"), draft: "y"), draft: "y", from: backend, deadline: .seconds(5)) }
        catch { thrown = error }
        #expect(thrown != nil)
        #expect(thrown.map { ActionFailure.model($0).reason } == .output)
    }

    @Test @MainActor func `capture failures use Actions' words`() {
        let tooLong = ActionFailure.capture(CorrectionError.failure(.tooLong, "x"))
        let failures = [
            ActionFailure.capture(EmptyDraft(geometry: .init(element: nil))),
            tooLong,
            .capture(CorrectionError.message(EditorAccess.secureFieldMessage)),
            .capture(CorrectionError.message("No editable composer has focus.")),
        ]
        #expect(failures.map(\.reason) == [.empty, .tooLong, .secure, .capture])
        #expect(tooLong.message.contains(ActionPrompt.maximumLength.formatted()))
        for failure in failures.dropLast() { #expect(!failure.message.lowercased().contains("correct")) }
    }

    @Test func `provider failures keep their reason`() {
        let pairs: [(CorrectionError.Reason, ActionFailure.Reason)] = [
            (.offline, .offline), (.slow, .slow), (.signIn, .signIn), (.limit, .limit), (.setup, .setup),
        ]
        for (reason, mapped) in pairs { #expect(ActionFailure.model(CorrectionError.failure(reason, "x")).reason == mapped) }
        #expect(ActionFailure.model(CorrectionError.message("x")).reason == .model)
    }

    @Test func `the capture limit is Actions' limit`() throws {
        #expect(ActionPrompt.maximumLength == 16_000)
        let nowhere = NSRange(location: 0, length: 0)
        #expect(throws: CorrectionError.self) { try TextTransaction(value: String(repeating: "a", count: 16_001), selection: nowhere) }
        _ = try TextTransaction(value: String(repeating: "a", count: 16_000), selection: nowhere)
    }

    @Test @MainActor func `failure labels never say correct`() {
        let reasons: [ActionFailure.Reason] = [.empty, .tooLong, .secure, .capture, .agentRun, .noModel, .offline, .slow, .signIn, .limit,
                                               .setup, .model, .output, .restore, .partial]
        for reason in reasons {
            let text = ActionFailure(reason, "x").label.text.lowercased()
            #expect(!text.isEmpty)
            #expect(!text.contains("fix") && !text.contains("correct"))
        }
    }

    @Test @MainActor func `copy capture names the asking feature's shortcut`() async throws {
        let opaque = OpaqueEditor(element: AXUIElementCreateSystemWide(), pid: 1, hostPID: nil, role: "AXTextArea", selected: false, empty: nil,
                                  snapshot: { _ in fatalError("nothing is captured") })
        let fix = ShortcutSettings.shared.label(.correct), actions = ShortcutSettings.shared.label(.actions)
        await #expect(throws: CorrectionError.message("Oops can’t read this editor’s text. Select the text to fix, then press \(fix).")) {
            try await EditorAccess().captureByCopy(opaque)
        }
        await #expect(throws: CorrectionError.message("Oops can’t read this editor’s text. Select the text, then press \(actions).")) {
            try await EditorAccess().captureByCopy(opaque, action: .actions, selecting: "the text")
        }
    }
}

private actor Recording: CorrectionBackend {
    let reply: String, delay: Duration?
    private(set) var sent: (text: String, instructions: String)?
    init(reply: String, delay: Duration? = nil) { self.reply = reply; self.delay = delay }
    func complete(_ text: String, instructions: String, deadline: Duration) async throws -> String {
        sent = (text, instructions)
        if let delay { try await Task.sleep(for: delay) }
        return reply
    }
}
