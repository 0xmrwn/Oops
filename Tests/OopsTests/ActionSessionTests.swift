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

    @Test func `an agent run fails before reading the draft`() async throws {
        let fixture = try Fixture()
        let top = try #require(ActionLibrary.starters.action(at: .up))
        fixture.library.update(top.id) { $0.runsWith = .init(kind: .agent) }
        let agent = try #require(fixture.library.library.action(at: .up))
        let outcome = await fixture.session.run(.saved(agent, value: nil))?.value
        #expect(outcome == .failed(.agentRun))
        #expect(!fixture.captured)
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

    @Test func `a partial write is put back at once and the answer is held`() async throws {
        let fixture = try Fixture(reply: #"{"text":"new"}"#)
        let original = try snapshot("old")
        fixture.capture = { original }
        let restored = Recorder<String>()
        fixture.session.editing.write = { _, snapshot, _ in throw PartialReplacement(applied: "half", done: 1, total: 3, snapshot: snapshot) }
        fixture.session.editing.restore = { snapshot, applied, _ in await restored.add(applied); return snapshot }
        let outcome = await fixture.session.run(.typed("x"))?.value
        #expect(outcome == .held)
        #expect(await restored.items == ["half"])
        #expect(fixture.session.written == nil)
        #expect(fixture.session.pending == "new")
        guard case .held? = fixture.drop.states.last else { Issue.record("expected the held state"); return }
    }

    @Test func `a partial write that can't be put back says so and keeps the answer`() async throws {
        let fixture = try Fixture(reply: #"{"text":"new"}"#)
        let original = try snapshot("old")
        fixture.capture = { original }
        fixture.session.editing.write = { _, snapshot, _ in throw PartialReplacement(applied: "half", done: 1, total: 3, snapshot: snapshot) }
        fixture.session.editing.restore = { _, _, _ in throw ActionDraftChanged() }
        let outcome = await fixture.session.run(.typed("x"))?.value
        #expect(outcome == .failed(.partlyWritten))
        #expect(fixture.drop.states.last == .failed(.partlyWritten))
        #expect(ActionFailure.partlyWritten.label.text == "Partly written")
        #expect(ActionFailure.partlyWritten.message.contains("changed in part and could not be put back"))
        #expect(fixture.session.pending == "new")
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
        private let reading = Reading()
        var captured: Bool { reading.captured }
        var capture: @MainActor () async throws -> EditorSnapshot {
            get { reading.capture }
            set { reading.capture = newValue }
        }
        private let suite = "oops-action-session-" + UUID().uuidString
        private let defaults: UserDefaults

        init(providers: Bool = true, reply: String? = nil) throws {
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
                                    capture: { reading.captured = true; return try await reading.capture() }, locate: { nil })
            session.forgetFix = { [weak self] in self?.forgotten += 1 }
        }

        deinit { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    }
}

/// What the session reads the draft with, and whether it did.
@MainActor private final class Reading {
    var captured = false
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
