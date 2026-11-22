import Foundation
@testable import Oops
import OopsCore
import Testing

/// Where the Actions tab goes on a click, back, or the tab chosen again.
@MainActor struct ActionsNavigationTests {
    private func navigation() throws -> ActionsNavigation {
        let defaults = try #require(UserDefaults(suiteName: "actions-navigation-\(UUID())"))
        return ActionsNavigation(library: ActionLibraryModel(store: ActionStore(defaults: defaults)))
    }

    @Test func `back from a new untouched action drops it`() throws {
        let navigation = try navigation()
        navigation.add(at: .upRight)
        #expect(navigation.editing != nil)
        #expect(navigation.library.draft != nil)
        navigation.back()
        #expect(navigation.editing == nil)
        #expect(navigation.library.draft == nil)
        #expect(navigation.library.library.actions.count == 4)
        #expect(!navigation.forward)
    }

    @Test func `back from runs with returns to its editor`() throws {
        let navigation = try navigation()
        let id = try #require(navigation.library.library.actions.first?.id)
        navigation.edit(id)
        navigation.openRunsWith(.action(id))
        navigation.back()
        #expect(navigation.editing == id)
        #expect(navigation.runsWith == nil)
    }

    @Test func `typed runs with returns to the wheel`() throws {
        let navigation = try navigation()
        navigation.openRunsWith(.typed)
        navigation.back()
        #expect(navigation.level == .init(editing: nil, runsWith: nil))
    }

    @Test func `choosing the tab again goes to the wheel`() throws {
        let navigation = try navigation()
        navigation.add(at: .upRight)
        let id = try #require(navigation.editing)
        navigation.openRunsWith(.action(id))
        navigation.backToWheel()
        #expect(navigation.level == .init(editing: nil, runsWith: nil))
        #expect(navigation.library.draft == nil)
    }

    @Test func `a written action stays when its editor is left`() throws {
        let navigation = try navigation()
        navigation.add(at: .upRight)
        let id = try #require(navigation.editing)
        navigation.library.update(id) { $0.name = "Expand" }
        navigation.back()
        #expect(navigation.library.library.action(at: .upRight)?.name == "Expand")
    }
}
