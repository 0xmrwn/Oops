import ApplicationServices
import Foundation
@testable import Oops
import OopsCore
import Testing

/// How a run starts and what it does before it reads a draft: the drop it takes, Fix's restore it forgets, and the
/// failures that stop it early.
@MainActor struct ActionSessionTests {
    @Test func `a second press while a run holds the drop is ignored`() async throws {
        let fixture = try Fixture()
        let gate = Signal()
        fixture.capture = { await gate.wait(); throw CancellationError() }
        let first = try #require(fixture.session.run(.typed("x")))
        #expect(fixture.session.run(.typed("x")) == nil)
        #expect(fixture.drop.claims == 1)
        await gate.release()
        #expect(await first.value == .cancelled)
    }

    @Test func `running an action forgets Fix's restore`() async throws {
        let fixture = try Fixture()
        fixture.capture = { throw EmptyDraft(geometry: .init(element: nil)) }
        _ = await fixture.session.run(.typed("x"))?.value
        #expect(fixture.forgotten == 1)
    }

    @Test func `a prepared draft is used instead of a new read`() async throws {
        let fixture = try Fixture()
        let draft = PreparedDraft { throw EmptyDraft(geometry: .init(element: nil)) }
        let outcome = await fixture.session.run(.typed("x"), draft: draft)?.value
        guard case .failed(let failure)? = outcome else { Issue.record("expected a failure, got \(String(describing: outcome))"); return }
        #expect(failure.reason == .empty)
        #expect(!fixture.captured, "the run never read the draft again")
    }

    @Test func `a field only copy reaches is copied from the editor found, never one focused since`() async throws {
        let fixture = try Fixture()
        let opaque = OpaqueEditor(element: AXUIElementCreateSystemWide(), pid: 1, hostPID: nil, role: "AXFound", selected: true, empty: nil,
                                  snapshot: { transaction in
                                      EditorSnapshot(element: AXUIElementCreateSystemWide(), pid: 1, hostPID: nil, appName: "Fixture", bundleID: nil,
                                                     owner: "Fixture", appVersion: nil, role: "AXFound", subrole: nil, transaction: transaction,
                                                     geometry: .init(element: nil))
                                  })
        let outcome = await fixture.session.run(.typed("x"), draft: PreparedDraft { throw opaque })?.value
        guard case .failed? = outcome else { Issue.record("expected a failure, got \(String(describing: outcome))"); return }
        #expect(fixture.reading.copied == ["AXFound"])
        #expect(!fixture.captured, "no new read of whatever has focus now")
    }

    @Test func `a prepared draft no run read is let go, on every way out`() async throws {
        let fixture = try Fixture()
        let released = Recorder<Int>()
        fixture.session.editing.disableAccessibility = { _ in await released.add(1) }
        let snapshot = try snapshot("x")
        let agent = try fixture.agentAction()
        let handed = PreparedDraft.holding { (snapshot, true) }
        _ = await fixture.session.run(.saved(agent, value: nil), draft: handed)?.value
        #expect(handed.released, "an agent run reads the field itself and lets the prepared read go")
        // Its switch goes only if the agent run is over by then: what follows counts from here.
        try await Task.sleep(for: .milliseconds(100))
        let base = await released.items.count

        fixture.drop.refuse = true
        #expect(fixture.session.run(.typed("x"), draft: PreparedDraft.holding { (snapshot, true) }) == nil)
        await released.until(base + 1)
        #expect(await released.items.count == base + 1, "a refused run lets go of it, and its switch with it")

        let draft = PreparedDraft.holding { (snapshot, true) }
        fixture.session.release(draft)
        fixture.session.release(draft)
        await released.until(base + 3)
        #expect(await released.items.count == base + 2, "once")
    }

    @Test func `a draft a run read is put back by the run alone`() async throws {
        let fixture = try Fixture(reply: #"{"text":"new"}"#)
        let released = Recorder<Int>()
        fixture.session.editing.disableAccessibility = { _ in await released.add(1) }
        fixture.session.editing.write = { _, snapshot, _ in snapshot }
        let snapshot = try snapshot("old")
        #expect(await fixture.session.run(.typed("x"), draft: PreparedDraft.holding { (snapshot, true) })?.value == .written)
        await released.until(2)
        #expect(await released.items.count == 1)
    }

    @Test func `an agent run without Claude Code fails before reading the draft`() async throws {
        let fixture = try Fixture()
        let agent = try fixture.agentAction()
        let outcome = await fixture.session.run(.saved(agent, value: nil))?.value
        let failure = ActionFailure.agent(ClaudeAgentError.notInstalled)
        #expect(failure.reason == .setup)
        #expect(outcome == .failed(failure))
        #expect(fixture.drop.states.last == .failed(failure))
        #expect(!fixture.captured)
    }

    @Test func `a second agent run is refused while one is under way, and a model run is not`() async throws {
        let calls = Recorder<Int>()
        let fixture = try Fixture(agent: { Task { await calls.add(1) }; return Silent() })
        let gate = Signal()
        fixture.capture = { await gate.wait(); throw CancellationError() }
        let agent = try fixture.agentAction()
        let first = try #require(fixture.session.run(.saved(agent, value: nil)))
        #expect(fixture.session.agent.isRunning)
        #expect(!fixture.session.isBusy, "an agent run leaves the session to model runs")
        let second = await fixture.session.run(.saved(agent, value: nil))?.value
        #expect(second == .failed(.agentBusy(agent.name)))
        #expect(fixture.drop.states.last == .failed(.agentBusy(agent.name)))
        fixture.session.agent.cancel()
        #expect(!fixture.session.agent.isRunning)
        await gate.release()
        #expect(await first.value == .cancelled)
        #expect(await calls.items.count == 1)
    }

    @Test func `a draft with an attachment is refused before any run, since one paste replaces all of it`() async throws {
        let fixture = try Fixture(reply: #"{"text":"new"}"#)
        fixture.capture = { try Self.snapshotValue("see \u{FFFC} for the plan") }
        let wrote = Recorder<String>()
        fixture.session.editing.write = { answer, snapshot, _ in await wrote.add(answer); return snapshot }
        let outcome = await fixture.session.run(.typed("x"))?.value
        #expect(outcome == .failed(.attachment))
        #expect(fixture.drop.states.last == .failed(.attachment))
        #expect(ActionFailure.attachment.label.text == "Has an attachment")
        #expect(await wrote.items.isEmpty)
        #expect(fixture.session.pending == nil, "the model was never asked")
    }

    @Test func `a run in Try refuses another app's field`() async throws {
        let fixture = try Fixture()
        fixture.capture = { try Self.snapshotValue("old") }
        fixture.session.tryDraftFocused = { true }
        let outcome = await fixture.session.run(.typed("x"), inTry: true)?.value
        #expect(outcome == .failed(ActionFailure(.capture, "Click into the draft, then press Run.")))
        #expect(fixture.session.lastInTry)
    }

    @Test func `a run in Try reads nothing unless the Try draft is focused`() async throws {
        let fixture = try Fixture()
        fixture.capture = { try Self.snapshotValue("old") }
        let outcome = await fixture.session.run(.typed("x"), inTry: true)?.value
        #expect(outcome == .failed(ActionFailure(.capture, "Click into the draft, then press Run.")))
        #expect(!fixture.captured)
    }

    @Test func `a write hands back the draft it left`() async throws {
        let fixture = try Fixture(reply: #"{"text":"new"}"#)
        fixture.capture = { try Self.snapshotValue("old") }
        fixture.session.editing.write = { _, snapshot, _ in snapshot }
        _ = await fixture.session.run(.typed("x"))?.value
        #expect(fixture.session.committed == "new")
    }

    @Test func `no model fails before reading the draft and opens Providers`() async throws {
        let fixture = try Fixture(providers: false)
        var opened: [Bool] = []
        fixture.session.openSettings = { opened.append($0) }
        let outcome = await fixture.session.run(.typed("x"))?.value
        #expect(outcome == .failed(.noModel))
        #expect(!fixture.captured)
        fixture.drop.controls.openSettings()
        #expect(opened == [true])
    }

    @Test func `a refused drop runs nothing`() throws {
        let fixture = try Fixture()
        fixture.drop.refuse = true
        #expect(fixture.session.run(.typed("x")) == nil)
        #expect(fixture.forgotten == 0)
    }

    @Test func `restore with nothing written fails with a reason`() async throws {
        let fixture = try Fixture()
        #expect(await fixture.session.restore()?.value == .failed(.nothingToRestore))
    }

    @Test func `a run cancelled while its drop is looked up leaves the drop alone`() async throws {
        let fixture = try Fixture(reply: #"{"text":"new"}"#)
        let original = try snapshot("old")
        fixture.capture = { original }
        fixture.session.editing.write = { _, snapshot, _ in snapshot }
        let reached = Signal(), gate = Signal()
        fixture.session.editing.geometry = { _ in await reached.release(); await gate.wait(); return nil }
        let first = try #require(fixture.session.run(.typed("x")))
        await reached.wait()
        fixture.session.cancel()
        await gate.release()
        _ = await first.value
        #expect(!fixture.drop.states.contains { if case .done = $0 { true } else { false } })
        let second = try #require(fixture.session.run(.typed("x")), "the session is free once the cancelled run has finished")
        _ = await second.value
    }

    @Test func `a cancelled run finishes its cleanup before another run starts`() async throws {
        let fixture = try Fixture(reply: #"{"text":"new"}"#)
        let original = try snapshot("old")
        fixture.capture = { original }
        let writing = Signal(), writeGate = Signal(), cleaning = Signal(), cleanGate = Signal()
        let cleaned = Recorder<Int>()
        fixture.session.editing.write = { _, _, _ in await writing.release(); await writeGate.wait(); throw CancellationError() }
        fixture.session.editing.disableAccessibility = { _ in await cleaning.release(); await cleanGate.wait(); await cleaned.add(1) }
        let first = try #require(fixture.session.run(.typed("x")))
        await writing.wait()
        fixture.session.cancel()
        #expect(fixture.session.isBusy)
        #expect(fixture.session.run(.typed("x")) == nil)
        await writeGate.release()
        await cleaning.wait()
        #expect(fixture.session.run(.typed("x")) == nil, "still switching accessibility back")
        await cleanGate.release()
        #expect(await first.value == .cancelled)
        #expect(await cleaned.items == [1])
        #expect(!fixture.session.isBusy)
    }

    @Test func `the restore record ends with the result drop`() async throws {
        let fixture = try Fixture(reply: #"{"text":"new"}"#)
        let original = try snapshot("old")
        fixture.capture = { original }
        fixture.session.editing.write = { _, snapshot, _ in snapshot }
        #expect(await fixture.session.run(.typed("x"))?.value == .written)
        #expect(fixture.session.written != nil)
        fixture.drop.controls.ended()
        #expect(fixture.session.written == nil)
        #expect(await fixture.session.restore()?.value == .failed(.nothingToRestore))
    }

    private static func snapshotValue(_ text: String) throws -> EditorSnapshot {
        EditorSnapshot(element: AXUIElementCreateSystemWide(), pid: 1, hostPID: nil, appName: "Fixture", bundleID: nil, owner: "Fixture",
                       appVersion: nil, role: "AXTextArea", subrole: nil,
                       transaction: try TextTransaction(value: text, selection: NSRange(location: 0, length: 0)), geometry: .init(element: nil))
    }
    private func snapshot(_ text: String) throws -> EditorSnapshot { try Self.snapshotValue(text) }

    @MainActor private final class Fixture {
        let drop = FakeActionDrop()
        let session: ActionSession
        let store: ActionStore
        let library: ActionLibraryModel
        var forgotten = 0
        let reading = Reading()
        var captured: Bool { reading.captured }
        var capture: @MainActor () async throws -> EditorSnapshot {
            get { reading.capture }
            set { reading.capture = newValue }
        }
        private let suite = "oops-action-session-" + UUID().uuidString
        private let defaults: UserDefaults

        /// An action that runs as an agent, saved in the fixture's library.
        func agentAction() throws -> Action {
            let top = try #require(ActionLibrary.starters.action(at: .up))
            library.update(top.id) { $0.runsWith = .init(kind: .agent) }
            return try #require(library.library.action(at: .up))
        }

        init(providers: Bool = true, reply: String? = nil, agent: (@MainActor () throws -> any AgentRunning)? = nil) throws {
            defaults = try #require(UserDefaults(suiteName: suite))
            if !providers {
                defaults.set(try JSONEncoder().encode([Provider]()), forKey: "providers")
                defaults.set(try JSONEncoder().encode(ModelSelection()), forKey: "modelSelection")
            }
            let local = Provider(id: "local", kind: .api(preset: nil), name: "Local fixture", baseURL: "http://127.0.0.1:1/v1", shownModels: ["m"])
            if providers {
                defaults.set(try JSONEncoder().encode([local]), forKey: "providers")
                defaults.set(try JSONEncoder().encode(ModelSelection(choice: .init(providerID: "local", modelID: "m"))), forKey: "modelSelection")
            }
            let providerStore = ProviderStore(chatGPT: ChatGPTAuth(store: NoCredentials(), openBrowser: { _ in }), preview: false,
                                              defaults: defaults, writeKey: { _, _ in }, readKey: { _ in "synthetic-key" },
                                              makeBackend: { _, _, _ in Replying(reply: reply) })
            store = ActionStore(defaults: defaults)
            library = ActionLibraryModel(store: store)
            let reading = reading
            session = ActionSession(editor: EditorAccess(), providers: providerStore, drop: drop, library: library,
                                    capture: { reading.captured = true; return try await reading.capture() },
                                    captureCopy: { opaque in reading.copied.append(opaque.role); throw EmptyDraft(geometry: .init(element: nil)) },
                                    locate: { nil }, agentRunner: agent ?? { throw ClaudeAgentError.notInstalled })
            session.forgetFix = { [weak self] in self?.forgotten += 1 }
        }

        deinit { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    }
}

/// What the session reads the draft with, and whether it did.
@MainActor private final class Reading {
    var captured = false
    /// The roles of the editors copied from.
    var copied: [String] = []
    var capture: @MainActor () async throws -> EditorSnapshot = { throw CancellationError() }
}

@MainActor private final class FakeActionDrop: ActionDrop {
    var controls = ActionDropControls()
    var canCancel = true, canRestore = false
    var refuse = false
    private(set) var claims = 0
    private(set) var states: [ActionDropState] = []
    func claim(busy: @escaping () -> Bool) -> Bool {
        guard !refuse else { return false }
        claims += 1
        return true
    }
    func show(_ state: ActionDropState, geometry: CapsulePlacement.Geometry?, element: AXUIElement?) { states.append(state) }
    func leave() {}
}

/// An agent that never answers.
private struct Silent: AgentRunning {
    func run(_ request: ClaudeAgentRequest) -> AsyncThrowingStream<ClaudeAgentUpdate, Error> { AsyncThrowingStream { _ in } }
}

private struct Replying: CorrectionBackend {
    let reply: String?
    func complete(_ text: String, instructions: String, deadline: Duration) async throws -> String {
        guard let reply else { throw CancellationError() }
        return reply
    }
}

private actor Recorder<Item: Sendable> {
    private(set) var items: [Item] = []
    func add(_ item: Item) { items.append(item) }
    /// Waits for `count` items, a second at most.
    func until(_ count: Int) async {
        let deadline = ContinuousClock.now + .seconds(1)
        while items.count < count, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    }
}

private actor Signal {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if released { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        released = true
        let pending = waiters; waiters = []
        for waiter in pending { waiter.resume() }
    }
}

private final class NoCredentials: ChatGPTStore, Sendable {
    func readProfile() throws -> ChatGPTProfile? { nil }
    func readCredentials() throws -> ChatGPTCredentials? { nil }
    func writeProfile(_ profile: ChatGPTProfile) throws {}
    func writeCredentials(_ credentials: ChatGPTCredentials) throws {}
    func deleteCredentials() throws {}
}
