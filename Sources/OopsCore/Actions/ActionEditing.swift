import Foundation

public extension Action {
    /// A new action's starting point: no name, no instruction, the sparkles icon.
    static func blank(at place: ActionPlace) -> Action { Action(symbol: "sparkles", name: "", instruction: "", place: place) }

    /// Nothing written yet; a new action left so is not kept.
    var isUntouched: Bool { name.trimmed.isEmpty && instruction.trimmed.isEmpty }

    /// What the wheel and the editor call it.
    var title: String { name.trimmed.isEmpty ? "New action" : name }
}

public extension ActionLibrary {
    /// Whether a new action can go at `place`: the place is free and the wheel isn't full.
    func canAdd(at place: ActionPlace) -> Bool { actions.count < Self.limit && action(at: place) == nil }

    /// Applies an edit to a saved action, or to `draft`, the new action not kept yet: the draft joins the library once
    /// it has a name or an instruction. Returns the draft still waiting, nil once it's kept.
    mutating func apply(_ edit: Action, draft: Action?) -> Action? {
        guard let draft, edit.id == draft.id else {
            update(edit)
            return draft
        }
        guard !edit.isUntouched, (try? add(edit)) != nil else { return edit.normalized() }
        return nil
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
