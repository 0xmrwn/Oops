import ApplicationServices
import Carbon
import Foundation
@testable import Oops
import OopsCore
import SwiftUI
import Testing

/// When the wheel opens and how it gives way: a run under way, another feature's drop, another shortcut, and the
/// restore its petal offers. No tap is made: these run without Accessibility.
@MainActor struct WheelControllerTests {
    @Test func `the shortcut is ignored while an action runs`() throws {
        let fixture = try Fixture()
        _ = try #require(fixture.actions.run(.typed("x")))
        fixture.wheel.shortcut()
        #expect(!fixture.wheel.isOpen)
        #expect(fixture.refusals.isEmpty, "a run under way is no reason to say anything")
        #expect(fixture.drop.holder == nil)
    }

    @Test func `Fix's drop keeps the wheel closed`() throws {
        let fixture = try Fixture()
        #expect(fixture.drop.claim(.fix, busy: { true }) { AnyView(EmptyView()) })
        fixture.wheel.shortcut()
        #expect(!fixture.wheel.isOpen)
        #expect(fixture.refusals == [CorrectionSession.dropTaken])
    }

    @Test func `the wheel holds the drop while open`() throws {
        let fixture = try Fixture()
        fixture.wheel.shortcut()
        #expect(fixture.wheel.isOpen)
        #expect(fixture.drop.holder == .actions)
        #expect(!fixture.drop.claim(.fix, busy: { false }) { AnyView(EmptyView()) })
        fixture.wheel.shortcut()
        #expect(!fixture.wheel.isOpen, "the shortcut again closes it")
        #expect(fixture.drop.holder == nil)
    }

    @Test func `another shortcut closes the wheel`() throws {
        let fixture = try Fixture()
        fixture.wheel.shortcut()
        fixture.wheel.yield()
        #expect(!fixture.wheel.isOpen)
        #expect(fixture.drop.holder == nil)
        #expect(fixture.drop.claim(.fix, busy: { false }) { AnyView(EmptyView()) })
    }

    @Test func `an edit in Settings is what the next opening offers`() throws {
        let fixture = try Fixture()
        let shorten = try #require(ActionLibrary.starters.action(at: .down))
        fixture.library.update(shorten.id) { $0.name = "Trim" }
        var run: Task<ActionOutcome, Never>?
        fixture.wheel.onRun = { run = $0 }
        fixture.wheel.shortcut()
        fixture.wheel.frame.choose(.down)
        #expect(run != nil)
        guard case .saved(let action, _)? = fixture.actions.last else { Issue.record("expected a saved action"); return }
        #expect(action.name == "Trim")
    }

    @Test func `the same direction restores what the result drop offered`() async throws {
        let fixture = try Fixture(reply: #"{"text":"short"}"#)
        let original = try EditorSnapshot(element: AXUIElementCreateSystemWide(), pid: 1, hostPID: nil, appName: "Fixture", bundleID: nil,
                                          owner: "Fixture", appVersion: nil, role: "AXTextArea", subrole: nil,
                                          transaction: TextTransaction(value: "a long draft", selection: NSRange(location: 0, length: 0)),
                                          geometry: .init(element: nil))
        fixture.capture = { original }
        fixture.actions.editing.write = { _, snapshot, _ in snapshot }
        fixture.actions.editing.enableAccessibility = { _ in false }
        fixture.actions.editing.geometry = { _ in nil }
        let restored = Count()
        fixture.actions.editing.restore = { snapshot, _, _ in restored.value += 1; return snapshot }
        let shorten = try #require(ActionLibrary.starters.action(at: .down))
        #expect(await fixture.actions.run(.saved(shorten, value: nil))?.value == .written)

        var run: Task<ActionOutcome, Never>?
        fixture.wheel.onRun = { run = $0 }
        fixture.wheel.shortcut()
        // Opening hides the result drop, which ends its record; the petal still restores what it offered.
        fixture.fakeDrop.controls.ended()
        fixture.wheel.frame.choose(.down)
        #expect(!fixture.wheel.isOpen)
        #expect(await run?.value == .restored)
        #expect(restored.value == 1)
    }

    @Test func `another Oops shortcut goes through the tap to its own handler`() throws {
        let fix = Shortcut(keyCode: 125, modifiers: UInt32(cmdKey))
        let fixture = try Fixture(chords: [fix], tapped: true)
        var runs = 0
        fixture.wheel.onRun = { _ in runs += 1 }
        fixture.wheel.shortcut()
        let keys = try #require(fixture.wheel.keys)
        func arrow(_ down: Bool, _ flags: CGEventFlags) -> Bool {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: 125, keyDown: down)!
            event.flags = flags
            return keys.handle(down ? .keyDown : .keyUp, event)
        }
        #expect(!arrow(true, .maskCommand), "⌘↓ is Fix's: it goes on, so Fix steps the wheel aside and runs")
        #expect(!arrow(false, .maskCommand))
        #expect(fixture.wheel.wheel.gesture.pointed == nil)
        #expect(runs == 0)
        #expect(arrow(true, []), "a bare arrow is still the wheel's")
        #expect(fixture.wheel.wheel.gesture.pointed == .down)
    }

    @Test func `the first ring is announced only while it is the one showing`() throws {
        let fixture = try Fixture()
        fixture.wheel.shortcut()
        #expect(fixture.wheel.openingAnnouncement()?.hasPrefix("Actions. Up: Sharpen prompt.") == true)
        fixture.wheel.frame.choose(.right)
        guard case .choices = fixture.wheel.wheel.level else { Issue.record("expected Translate's ring"); return }
        #expect(fixture.wheel.openingAnnouncement() == nil, "a ring entered early says itself when it blooms")
    }

    @Test func `the field read stops when it loses the race or its caller goes`() async throws {
        let stopped = Stops()
        let slow: @Sendable () async -> Int? = {
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
            await stopped.add()
            return 1
        }
        #expect(await WheelController.reading(within: .milliseconds(30), slow) == nil)
        await stopped.until(1)
        #expect(await stopped.count == 1)

        let caller = Task { await WheelController.reading(within: .seconds(10), slow) }
        try await Task.sleep(for: .milliseconds(30))
        caller.cancel()
        #expect(await caller.value == nil)
        await stopped.until(2)
        #expect(await stopped.count == 2)
    }

    @MainActor private final class Fixture {
        let drop = DropOwner()
        let fakeDrop = FakeDrop()
        let actions: ActionSession
        let library: ActionLibraryModel
        let wheel: WheelController
        var refusals: [String] = []
        private let reading = Reading()
        var capture: @MainActor () async throws -> EditorSnapshot {
            get { reading.capture }
            set { reading.capture = newValue }
        }
        private let suite = "oops-wheel-controller-" + UUID().uuidString

        init(reply: String? = nil, chords: [Shortcut] = [], tapped: Bool = false) throws {
            let defaults = try #require(UserDefaults(suiteName: suite))
            let local = Provider(id: "local", kind: .api(preset: nil), name: "Local fixture", baseURL: "http://127.0.0.1:1/v1", shownModels: ["m"])
            defaults.set(try JSONEncoder().encode([local]), forKey: "providers")
            defaults.set(try JSONEncoder().encode(ModelSelection(choice: .init(providerID: "local", modelID: "m"))), forKey: "modelSelection")
            let providers = ProviderStore(chatGPT: ChatGPTAuth(store: NoCredentials(), openBrowser: { _ in }), preview: false,
                                          defaults: defaults, writeKey: { _, _ in }, readKey: { _ in "synthetic-key" },
                                          makeBackend: { _, _, _ in Replying(reply: reply) })
            let reading = reading
            library = ActionLibraryModel(store: ActionStore(defaults: defaults))
            actions = ActionSession(editor: EditorAccess(), providers: providers, drop: fakeDrop, library: library,
                                    capture: { try await reading.capture() }, locate: { nil })
            let library = library
            wheel = WheelController(actions: actions, drop: drop, editor: EditorAccess(), library: { library.library }, chords: { chords },
                                    makeKeys: { tapped ? try WheelKeys(chords: $0, deliver: $1, listening: false) : nil })
            wheel.refused = { [weak self] in self?.refusals.append($0) }
        }

        deinit { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    }
}

@MainActor private final class Reading {
    var capture: @MainActor () async throws -> EditorSnapshot = { throw CancellationError() }
}

@MainActor private final class Count {
    var value = 0
}

@MainActor private final class FakeDrop: ActionDrop {
    var controls = ActionDropControls()
    var canCancel = true, canRestore = false
    func claim(busy: @escaping () -> Bool) -> Bool { true }
    func show(_ state: ActionDropState, geometry: CapsulePlacement.Geometry?, element: AXUIElement?) {}
    func leave() {}
}

private struct Replying: CorrectionBackend {
    let reply: String?
    func complete(_ text: String, instructions: String, deadline: Duration) async throws -> String {
        guard let reply else { throw CancellationError() }
        return reply
    }
}

private final class NoCredentials: ChatGPTStore, Sendable {
    func readProfile() throws -> ChatGPTProfile? { nil }
    func readCredentials() throws -> ChatGPTCredentials? { nil }
    func writeProfile(_ profile: ChatGPTProfile) throws {}
    func writeCredentials(_ credentials: ChatGPTCredentials) throws {}
    func deleteCredentials() throws {}
}

private actor Stops {
    private(set) var count = 0
    func add() { count += 1 }
    /// Waits for `count` stops, a few seconds at most.
    func until(_ count: Int) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while self.count < count, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    }
}
