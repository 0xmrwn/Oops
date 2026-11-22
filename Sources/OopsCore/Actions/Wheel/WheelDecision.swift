import Foundation

/// What choosing a place does.
public enum WheelDecision: Equatable, Sendable {
    case restore, run(ActionInvocation), openChoices(Action), nothing

    /// The first ring: the action that was just run restores (its choice not asked again); an action with a choice
    /// opens its ring, even an empty one; any other runs.
    public static func root(_ place: ActionPlace, in library: ActionLibrary, restorable: UUID?) -> WheelDecision {
        guard let action = library.action(at: place) else { return .nothing }
        if action.id == restorable { return .restore }
        if action.choice != nil { return .openChoices(action) }
        return .run(.saved(action, value: nil))
    }

    /// The second ring: the value at `place` runs `action` with it.
    public static func value(_ place: ActionPlace, of action: Action) -> WheelDecision {
        guard let value = action.choice?.values[place], !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .nothing }
        return .run(.saved(action, value: value))
    }
}
