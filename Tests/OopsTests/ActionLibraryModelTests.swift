import Foundation
@testable import Oops
import OopsCore
import Testing

/// The shared library: what Settings edits is saved at once, and a new action is kept only once it has words.
@MainActor struct ActionLibraryModelTests {
    private func defaults() throws -> UserDefaults { try #require(UserDefaults(suiteName: "actions-model-\(UUID())")) }

    @Test func `a new action is not saved until it has words`() throws {
        let defaults = try defaults()
        let model = ActionLibraryModel(store: ActionStore(defaults: defaults))
        let id = try #require(model.startNew(at: .upRight))
        #expect(model.library.actions.count == 4)
        #expect(defaults.object(forKey: ActionStore.key) == nil)
        model.update(id) { $0.name = "Expand" }
        #expect(model.library.actions.count == 5)
        #expect(model.draft == nil)
        #expect(ActionStore(defaults: defaults).load().actions.count == 5)
    }

    @Test func `starting at a taken place or on a full wheel gives nothing`() throws {
        let model = ActionLibraryModel(store: ActionStore(defaults: try defaults()))
        #expect(model.startNew(at: .up) == nil)
        for place in [ActionPlace.upRight, .downRight, .downLeft, .upLeft] {
            let id = try #require(model.startNew(at: place))
            model.update(id) { $0.name = "Extra" }
        }
        for place in ActionPlace.allCases { #expect(model.startNew(at: place) == nil) }
    }

    @Test func `moving onto another action swaps them and saves`() throws {
        let defaults = try defaults()
        let model = ActionLibraryModel(store: ActionStore(defaults: defaults))
        let translate = try #require(model.library.actions.first { $0.name == "Translate" })
        model.move(translate.id, to: .up)
        #expect(model.library.action(at: .up)?.name == "Translate")
        #expect(model.library.action(at: .right)?.name == "Sharpen prompt")
        #expect(ActionStore(defaults: defaults).load() == model.library)
    }

    @Test func `the typed instruction's run is saved`() throws {
        let defaults = try defaults()
        let model = ActionLibraryModel(store: ActionStore(defaults: defaults))
        model.setTyped(.init(kind: .agent))
        #expect(ActionStore(defaults: defaults).load().typed.kind == .agent)
    }

    @Test func `preview saves nothing`() throws {
        let defaults = try defaults()
        let model = ActionLibraryModel(store: ActionStore(defaults: defaults), preview: true)
        let top = try #require(model.library.action(at: .up))
        model.update(top.id) { $0.name = "Changed" }
        #expect(model.library.action(at: .up)?.name == "Changed")
        #expect(defaults.object(forKey: ActionStore.key) == nil)
    }
}
