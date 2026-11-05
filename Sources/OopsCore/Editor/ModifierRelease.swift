import Foundation

/// Called before the input gate, while modifier-release events can still flow.
public enum ModifierRelease {
    /// `isReleased` reads every event source; `keyboardReleased` only the hardware. Another app's
    /// virtual keyboard can leave a modifier set in the first for minutes: once the wait is up, a
    /// modifier no key is holding doesn't block the swap.
    @discardableResult public static func wait(
        isReleased: () -> Bool,
        keyboardReleased: () -> Bool = { false },
        now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        pause: (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) async throws -> Int {
        let deadline = now() + 1
        var waits = 0
        var observedRelease = false
        // No timer/event tap at idle. During a pending swap, wait at most one
        // second and require two released samples if modifiers were held.
        while waits <= 110 {
            try Task.checkCancellation()
            guard now() <= deadline else { break }
            let released = isReleased()
            guard now() <= deadline else { break }
            if released, waits == 0 || observedRelease { return waits }
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
