import Foundation

/// The wheel's typed centre: where it is offered and what it says.
public enum WheelTyping {
    /// Apps measured to lose their field, caret or selection while Oops's field holds the keys for a moment
    /// (`fixtures/compat/run.py --focus-trip`): the centre doesn't take typing there; arrows and clicks still work.
    public static let unavailable: Set<String> = []

    public static func isAvailable(bundleID: String?, unavailable: Set<String> = unavailable) -> Bool {
        bundleID.map { !unavailable.contains($0) } ?? true
    }

    /// The words under the centre once the names show, and the field's placeholder: an instruction at the first
    /// ring, the choice's name at an action's ring.
    public static func hint(at level: Wheel.Level) -> String? {
        switch level {
        case .root, .typing(from: .root): "Type an instruction"
        case let .choices(action), let .typing(from: .choices(action)): action.choice?.name ?? action.name
        case .closed: nil
        }
    }
}

public extension Wheel {
    /// The centre becomes a field: from either ring, while no arrow is held or about to commit. Both rings go back
    /// into the centre.
    mutating func type(at now: TimeInterval) -> [WheelEffect] {
        guard canType, gesture.held.isEmpty, gesture.commitAt == nil else { return [] }
        let from: Typing
        switch level {
        case .root: from = .root
        case let .choices(action): from = .choices(action)
        case .closed, .typing: return []
        }
        let placeholder = WheelTyping.hint(at: level) ?? ""
        level = .typing(from: from)
        gesture.reset()
        flicking = false
        return [.beginTyping(placeholder: placeholder)]
    }

    /// A click on the centre: the same as starting to type.
    mutating func clickCentre(at now: TimeInterval) -> [WheelEffect] { type(at: now) }

    /// Return in the field: an instruction runs as typed, a value runs its action with it. Nothing typed does nothing.
    mutating func submit(_ text: String) -> [WheelEffect] {
        guard case let .typing(from) = level else { return [] }
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return [] }
        level = .closed
        gesture.reset()
        switch from {
        case .root: return [.run(.typed(words)), .close]
        case let .choices(action): return [.run(.saved(action, value: words)), .close]
        }
    }

    /// The field never took the keys: back to the ring it came from, which blooms again.
    mutating func typingFailed(at now: TimeInterval) -> [WheelEffect] {
        guard case let .typing(from) = level else { return [] }
        switch from {
        case .root: level = .root
        case let .choices(action): level = .choices(action)
        }
        bloomed = true
        hinted = false
        lingerAt = now + WheelTiming.linger
        if level == .root {
            named = false
            return [.bloom(WheelLayout.ordered(filled))]
        }
        return [.bloomChoices(WheelLayout.ordered(filled))]
    }
}
