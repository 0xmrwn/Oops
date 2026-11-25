import Foundation
import OopsCore

/// Whether the wheel still teaches its typed centre, kept across launches (`WheelCue`).
extension WheelController {
    /// Set once an instruction has been typed in the wheel; and how many openings have shown the cue.
    static let typedKey = "WheelTypedInstruction", cueOpensKey = "WheelTypingCueOpens"

    /// Whether this opening shows the cue, counted as one of its opens when it does.
    func teachesTyping(_ defaults: UserDefaults = .standard) -> Bool {
        switch DebugFlags.wheelTypingCue {
        case "always": return true
        case "never": return false
        case "reset" where !Self.cueReset:
            Self.cueReset = true
            defaults.removeObject(forKey: Self.typedKey)
            defaults.removeObject(forKey: Self.cueOpensKey)
        default: break
        }
        let opens = defaults.integer(forKey: Self.cueOpensKey)
        guard WheelCue.shows(typed: defaults.bool(forKey: Self.typedKey), opens: opens) else { return false }
        defaults.set(opens + 1, forKey: Self.cueOpensKey)
        return true
    }

    /// An instruction was typed in the wheel: it opens without the cue from now on. A forced cue saves nothing.
    func learnedTyping(_ defaults: UserDefaults = .standard) {
        guard !["always", "never"].contains(DebugFlags.wheelTypingCue) else { return }
        defaults.set(true, forKey: Self.typedKey)
    }

    /// Debug builds' `-WheelTypingCue reset` clears what was learned once per launch, not at every opening.
    private static var cueReset = false
}
