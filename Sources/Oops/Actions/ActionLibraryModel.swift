import Foundation
import Observation
import OopsCore

/// Every saved action and how a typed instruction runs, for Settings and the run alike: an edit in Settings is what the
/// next run reads. A new action being written waits as `draft`, off the wheel, until it has a name or an instruction.
@Observable @MainActor final class ActionLibraryModel {
    static let shared = ActionLibraryModel(preview: DebugFlags.actionsPreview)
    private(set) var library: ActionLibrary
    /// A new action not kept yet.
    private(set) var draft: Action?
    @ObservationIgnored private let store: ActionStore
    /// Captures only: starts from the starters and saves nothing.
    @ObservationIgnored private let preview: Bool

    init(store: ActionStore = ActionStore(), preview: Bool = false) {
        self.store = store
        self.preview = preview
        library = preview ? .starters : store.load()
    }

    /// The draft or a saved action.
    func action(_ id: UUID) -> Action? { draft?.id == id ? draft : library.actions.first { $0.id == id } }

    /// Starts a new action at `place`; nil when the place is taken or the wheel is full.
    @discardableResult func startNew(at place: ActionPlace) -> UUID? {
        guard library.canAdd(at: place) else { return nil }
        let action = Action.blank(at: place)
        draft = action
        return action.id
    }

    func update(_ action: Action) {
        var next = library
        draft = next.apply(action, draft: draft)
        commit(next)
    }

    func update(_ id: UUID, _ change: (inout Action) -> Void) {
        guard var action = action(id) else { return }
        change(&action)
        update(action)
    }

    func move(_ id: UUID, to place: ActionPlace) {
        var next = library
        next.move(id, to: place)
        commit(next)
    }

    func remove(_ id: UUID) {
        if draft?.id == id { draft = nil; return }
        var next = library
        next.remove(id)
        commit(next)
    }

    func discardDraft() { draft = nil }

    func setTyped(_ runsWith: ActionRunsWith) {
        var next = library
        next.typed = runsWith
        commit(next)
    }

    private func commit(_ next: ActionLibrary) {
        guard next != library else { return }
        library = next
        if !preview { store.save(library) }
    }
}
