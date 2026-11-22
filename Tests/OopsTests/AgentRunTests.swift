import ApplicationServices
import Foundation
@testable import Oops
import OopsCore
import SwiftUI
import Testing

/// An agent run's result and retries: where a retry goes, what a ready result waits for, what Undo and the wheel can
/// restore, and what runs nothing. No drop is shown: every claim here is refused or never made.
@MainActor struct AgentRunTests {
    @Test func `a retry of a run begun in Try goes back through Try`() async throws {
        let fixture = try Fixture()
        var retried: [ActionInvocation] = []
        fixture.session.retryInTry = { retried.append($0) }
        let invocation = ActionInvocation.saved(try fixture.agentAction(), value: nil)
        let outcome = await fixture.session.run(invocation, inTry: true)?.value
        #expect(outcome == .failed(ActionFailure(.capture, "Click into the draft, then press Run.")))
        fixture.drop.controls.retry()
        fixture.session.agent.retry()
        #expect(retried == [invocation, invocation])
        #expect(fixture.runs == 0, "nothing read another app's draft")
    }

    @Test func `a retry after a failure before the start repeats that agent action`() async throws {
        let fixture = try Fixture()
        let invocation = ActionInvocation.saved(try fixture.agentAction(), value: nil)
        _ = await fixture.session.run(invocation)?.value
        #expect(fixture.session.last == invocation)
        #expect(!fixture.session.lastInTry)
        fixture.drop.controls.retry()
        for _ in 0 ..< 100 where fixture.runs < 2 { await Task.yield() }
        #expect(fixture.runs == 2)
    }

    @Test func `an agent's write can be restored by Undo or the wheel while its drop is up`() async throws {
        let fixture = try Fixture()
        let invocation = ActionInvocation.saved(try fixture.agentAction(), value: nil)
        _ = await fixture.session.run(invocation)?.value
        fixture.session.last = nil
        let agent = fixture.session.agent
        agent.keep(.init(snapshot: try Self.snapshot("new"), applied: "new"))
        #expect(fixture.session.canRestore)
        #expect(fixture.session.last == invocation)
        agent.dropEnded()
        #expect(!fixture.session.canRestore)
        #expect(agent.kept == nil)
    }

    @Test func `a ready result stays ready while another feature holds the drop`() {
        let owner = DropOwner()
        #expect(owner.claim(.fix, busy: { true }) { AnyView(EmptyView()) })
        let agent = Self.agent(owner)
        var said: [String] = []
        agent.refused = { said.append($0) }
        agent.handle(.started); agent.handle(.focus(false))
        agent.held = "answer"
        agent.handle(.answered)
        #expect(agent.isReady)
        agent.act()
        #expect(agent.isReady)
        #expect(agent.held == "answer")
        #expect(said.count == 1)
    }

    @Test func `a ready result tells its run how it ended`() async {
        let owner = DropOwner()
        #expect(owner.claim(.fix, busy: { true }) { AnyView(EmptyView()) })
        let agent = Self.agent(owner)
        agent.handle(.started); agent.handle(.focus(false)); agent.handle(.answered)
        let waiting = Task { await agent.readyOutcome() }
        for _ in 0 ..< 10 { await Task.yield() }
        agent.dismiss()
        #expect(await waiting.value == .cancelled)
        #expect(!agent.isReady)
    }

    @Test func `a draft changed in part keeps its own words in the held drop`() {
        #expect(AgentRun.held(ActionFailure.partlyWritten) == ("Partly written", ActionFailure.partlyWritten.message))
        #expect(AgentRun.held(ActionDraftChanged()).label == "Not written")
        #expect(AgentRun.held(ActionFailure(.model, "busy")) == ("Not written", "busy"))
    }

    @Test func `nothing runs unless Claude Code is set up as a provider`() throws {
        // A local provider only, as after Claude Code was removed in Settings: an executable on the Mac isn't enough.
        let fixture = try Fixture()
        #expect(throws: ClaudeAgentError.notInstalled) { try fixture.session.providers.checkAgentProvider() }
        #expect(throws: ClaudeAgentError.notInstalled) { _ = try fixture.session.providers.agentRunner() }
    }

    @Test func `a held accessibility switch is let go by its last holder`() {
        let switches = AccessibilitySwitches()
        #expect(!switches.isHeld(42))
        switches.hold(42); switches.hold(42)
        #expect(!switches.release(42))
        #expect(switches.isHeld(42))
        #expect(switches.release(42))
        #expect(!switches.isHeld(42))
        #expect(switches.release(42), "an extra release changes nothing")
    }

    private static func agent(_ owner: DropOwner) -> AgentRun {
        let agent = AgentRun(drop: AgentDrop(owner: owner) { _ in nil }, editor: EditorAccess(), runner: { throw ClaudeAgentError.notInstalled })
        agent.cue = { _ in }
        return agent
    }

    private static func snapshot(_ text: String) throws -> EditorSnapshot {
        EditorSnapshot(element: AXUIElementCreateSystemWide(), pid: 1, hostPID: nil, appName: "Fixture", bundleID: nil, owner: "Fixture",
                       appVersion: nil, role: "AXTextArea", subrole: nil,
                       transaction: try TextTransaction(value: text, selection: NSRange(location: 0, length: 0)), geometry: .init(element: nil))
    }

    @MainActor private final class Fixture {
        let drop = RecordingDrop()
        let session: ActionSession
        let library: ActionLibraryModel
        /// How many times a runner was asked for: once per run that got past Try's check.
        var runs: Int { counter.value }
        private let counter = Counter()
        private let suite = "oops-agent-run-" + UUID().uuidString

        init() throws {
            let defaults = try #require(UserDefaults(suiteName: suite))
            let local = Provider(id: "local", kind: .api(preset: nil), name: "Local fixture", baseURL: "http://127.0.0.1:1/v1", shownModels: ["m"])
            defaults.set(try JSONEncoder().encode([local]), forKey: "providers")
            defaults.set(try JSONEncoder().encode(ModelSelection(choice: .init(providerID: "local", modelID: "m"))), forKey: "modelSelection")
            let store = ProviderStore(chatGPT: ChatGPTAuth(store: NoCredentials(), openBrowser: { _ in }), preview: false,
                                      defaults: defaults, writeKey: { _, _ in }, readKey: { _ in "synthetic-key" })
            library = ActionLibraryModel(store: ActionStore(defaults: defaults))
            let counter = counter
            session = ActionSession(editor: EditorAccess(), providers: store, drop: drop, library: library, capture: { throw CancellationError() },
                                    locate: { nil }, agentRunner: { counter.value += 1; throw ClaudeAgentError.notInstalled })
        }

        func agentAction() throws -> Action {
            let top = try #require(ActionLibrary.starters.action(at: .up))
            library.update(top.id) { $0.runsWith = .init(kind: .agent) }
            return try #require(library.library.action(at: .up))
        }

        deinit { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    }
}

@MainActor private final class Counter { var value = 0 }

@MainActor private final class RecordingDrop: ActionDrop {
    var controls = ActionDropControls()
    var canCancel = true, canRestore = false
    func claim(busy: @escaping () -> Bool) -> Bool { true }
    func show(_ state: ActionDropState, geometry: CapsulePlacement.Geometry?, element: AXUIElement?) {}
    func leave() {}
}

private final class NoCredentials: ChatGPTStore, Sendable {
    func readProfile() throws -> ChatGPTProfile? { nil }
    func readCredentials() throws -> ChatGPTCredentials? { nil }
    func writeProfile(_ profile: ChatGPTProfile) throws {}
    func writeCredentials(_ credentials: ChatGPTCredentials) throws {}
    func deleteCredentials() throws {}
}
