import Foundation

/// Called before the input gate, while modifier-release events can still flow.
public enum ModifierRelease {
    /// `isReleased` reads every event source; `keyboardReleased` only the hardware. Another app's
    /// virtual keyboard can leave a modifier set in the first for minutes: a modifier no key is holding
    /// doesn't block the swap once the hardware has read as released for `staleAfter` samples in a row.
    /// That is long enough for a remapper's own release events to arrive, and far short of the window.
    /// A correction starts on the shortcut's press, so its keys may still be down when the edit is
    /// ready: `shortcutHeld` is waited out first, for up to `holdLimit`, before the one-second window.
    @discardableResult public static func wait(
        shortcutHeld: () -> Bool = { false },
        holdLimit: TimeInterval = 10,
        isReleased: () -> Bool,
        keyboardReleased: () -> Bool = { false },
        now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        pause: (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) async throws -> Int {
        let holdDeadline = now() + holdLimit
        while shortcutHeld(), now() < holdDeadline {
            try Task.checkCancellation()
            try await pause(0.01)
        }
        let deadline = now() + 1
        let staleAfter = 15
        var waits = 0
        var observedRelease = false
        var hardwareRun = 0
        // No timer/event tap at idle. During a pending swap, wait at most one
        // second and require two released samples if modifiers were held.
        while waits <= 110 {
            try Task.checkCancellation()
            guard now() <= deadline else { break }
            let released = isReleased()
            hardwareRun = !released && keyboardReleased() ? hardwareRun + 1 : 0
            guard now() <= deadline else { break }
            if released, waits == 0 || observedRelease { return waits }
            if hardwareRun >= staleAfter { return waits }
            observedRelease = released
            let remaining = deadline - now()
            guard remaining > 0 else { break }
            try await pause(min(0.01, remaining))
            waits += 1
        }
        if keyboardReleased() { return waits }
        throw CorrectionError.message("Release the shortcut’s keys and try again. Nothing replaced.")
    }
}
