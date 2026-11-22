import Foundation
@testable import Oops
import OopsCore
import Testing

/// The Actions drop and Fix's share one panel and one model: each gets its own buttons when it holds the drop.
@MainActor struct ActionDropOwnerTests {
    @Test func `Fix takes its drop's buttons back from Actions`() throws {
        let fixture = try Fixture()
        var copies = 0
        fixture.actions.controls.copy = { copies += 1 }
        #expect(fixture.actions.claim(busy: { false }))
        fixture.drop.panel.model.copy?()
        #expect(copies == 1)
        #expect(fixture.fix.holdDrop())
        fixture.drop.panel.model.copy?()
        #expect(copies == 1, "the copy button is Fix's again")
    }

    @Test func `each feature names the drop's controls its own way`() throws {
        let fixture = try Fixture()
        #expect(fixture.drop.panel.model.words == .fix)
        #expect(fixture.actions.claim(busy: { false }))
        #expect(fixture.drop.panel.model.words == .actions)
        #expect(DropWords.actions.cancelShortcut == nil, "Fix's chord does not cancel an action")
        #expect(fixture.fix.holdDrop())
        #expect(fixture.drop.panel.model.words == .fix)
    }

    @Test func `while an action runs Fix can't take the drop`() throws {
        let fixture = try Fixture()
        #expect(fixture.actions.claim(busy: { true }))
        #expect(!fixture.fix.holdDrop())
        #expect(fixture.drop.holder == .actions)
    }

    @Test func `Actions leaves the shared model alone once Fix shows`() throws {
        let fixture = try Fixture()
        #expect(fixture.actions.claim(busy: { false }))
        #expect(fixture.fix.holdDrop())
        fixture.actions.canRestore = true
        #expect(!fixture.drop.panel.model.canRevert)
    }

    @Test func `Actions hears when its drop hides`() throws {
        let fixture = try Fixture()
        var ended = 0
        fixture.actions.controls.ended = { ended += 1 }
        #expect(fixture.actions.claim(busy: { false }))
        #expect(ended == 0)
        fixture.drop.panel.hide()
        #expect(ended == 1)
    }

    @Test func `Actions hears when Fix takes its drop`() throws {
        let fixture = try Fixture()
        var ended = 0
        fixture.actions.controls.ended = { ended += 1 }
        #expect(fixture.actions.claim(busy: { false }))
        #expect(fixture.actions.claim(busy: { false }))
        #expect(ended == 0, "claiming again for its own run keeps the record")
        #expect(fixture.fix.holdDrop())
        #expect(ended == 1)
        fixture.drop.panel.hide()
        #expect(ended == 1, "the drop is Fix's now")
    }

    @MainActor private final class Fixture {
        let drop = DropOwner()
        let fix: CorrectionSession
        let actions: ActionDropOwner
        private let suite = "oops-action-drop-" + UUID().uuidString
        private let defaults: UserDefaults

        init() throws {
            defaults = try #require(UserDefaults(suiteName: suite))
            let preferences = Preferences(auth: ChatGPTAuth(store: NoCredentials(), openBrowser: { _ in }), defaults: defaults)
            fix = CorrectionSession(preferences: preferences, testEditor: TestEditorModel(), drop: drop)
            actions = ActionDropOwner(owner: drop) { _ in nil }
        }

        deinit {
            MainActor.assumeIsolated { drop.panel.hide() }
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
    }
}

private final class NoCredentials: ChatGPTStore, Sendable {
    func readProfile() throws -> ChatGPTProfile? { nil }
    func readCredentials() throws -> ChatGPTCredentials? { nil }
    func writeProfile(_ profile: ChatGPTProfile) throws {}
    func writeCredentials(_ credentials: ChatGPTCredentials) throws {}
    func deleteCredentials() throws {}
}
