import Foundation
import OopsCore

/// Whether the wheel still teaches its typed centre, kept across launches (`WheelCue`).
extension WheelController {
    /// Set once an instruction has been typed in the wheel; and how many openings have shown the cue's words.
    static let typedKey = "WheelTypedInstruction", cueOpensKey = "WheelTypingCueOpens"

    /// Whether this opening teaches the typed centre.
    static func teachesTyping(_ defaults: UserDefaults = .standard) -> Bool {
        switch DebugFlags.wheelTypingCue {
        case "always": return true
        case "never": return false
        case "reset" where !cueReset:
            cueReset = true
            defaults.removeObject(forKey: typedKey)
            defaults.removeObject(forKey: cueOpensKey)
        default: break
        }
        return WheelCue.shows(typed: defaults.bool(forKey: typedKey), opens: defaults.integer(forKey: cueOpensKey))
    }

    /// The cue's words appeared: one of its opens is used. A cue pointed or typed away before then costs none.
    static func countCueOpen(_ defaults: UserDefaults = .standard) {
        guard !forced else { return }
        defaults.set(defaults.integer(forKey: cueOpensKey) + 1, forKey: cueOpensKey)
    }

    /// An instruction was typed in the wheel: it opens without the cue from now on.
    static func learnedTyping(_ defaults: UserDefaults = .standard) {
        guard !forced else { return }
        defaults.set(true, forKey: typedKey)
    }

    /// A forced cue saves nothing.
    private static var forced: Bool { ["always", "never"].contains(DebugFlags.wheelTypingCue) }
    /// Debug builds' `-WheelTypingCue reset` clears what was learned once per launch, not at every opening.
    private static var cueReset = false
}
