import Foundation

/// Return or Escape, pressed while an agent run's ready drop waits at the caret of its field: Return puts the answer
/// in, Escape sends the drop back to the pill. Each press is decided as it arrives, and only one that passes every
/// check is taken from the app; every other press, and every other key, reaches the app untouched.
public enum AgentReadyKey: Equatable, Sendable {
    case confirm, escape

    /// The key a press stands for: plain Return or Escape only. A held modifier, keypad Enter or a repeat is the app's.
    public init?(keyCode: Int64, modifiers: Bool, repeating: Bool) {
        guard !modifiers, !repeating else { return nil }
        switch keyCode {
        case 36: self = .confirm
        case 53: self = .escape
        default: return nil
        }
    }

    /// Whether to take the press: the run's ready drop is the one up (`inFront`), at the caret of the run's field
    /// (`atCaret`), that field has focus right now, and the draft still reads as it was read. The last two are checked
    /// live as the key arrives; nil means the check didn't finish in time, and the key goes to the app.
    public static func takes(inFront: Bool, atCaret: Bool, focused: Bool?, unchanged: Bool?) -> Bool {
        inFront && atCaret && focused == true && unchanged == true
    }
}
