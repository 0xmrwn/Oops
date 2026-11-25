import AppKit
import OopsCore

/// While a shortcut records: samples the keyboard for a chord another app takes before the recorder hears it
/// (`ShortcutConflict`). A key reads down in the session's state or the keyboard's, as the missed-release
/// watch reads it; modifiers come from the keyboard and from what the recorder saw, never from the session,
/// where a remapper can leave one set.
@MainActor final class ShortcutConflictProbe {
    private var conflict: ShortcutConflict
    private var task: Task<Void, Never>?

    /// `held`: the Carbon modifiers the recorder saw go down. `found` gets each chord taken.
    init(held: @escaping () -> UInt32, found: @escaping (Shortcut) -> Void) {
        conflict = ShortcutConflict(alreadyDown: Self.keysDown())
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: ShortcutConflict.interval)
                guard !Task.isCancelled, let self else { return }
                let keyboard = NSEvent.ModifierFlags(rawValue: UInt(CGEventSource.flagsState(.hidSystemState).rawValue))
                if let chord = conflict.sample(down: Self.keysDown(), modifiers: Shortcut.modifiers(keyboard) | held(), at: .now) {
                    found(Shortcut(keyCode: UInt32(chord.keyCode), modifiers: chord.modifiers))
                }
            }
        }
    }

    /// The recorder heard a key-down; a repeat acknowledges nothing.
    func heard(_ event: NSEvent) { conflict.heard(event.keyCode, isRepeat: event.isARepeat) }

    func stop() { task?.cancel(); task = nil }

    private static func keysDown() -> Set<UInt16> {
        Set((UInt16(0) ..< 128).filter { CGEventSource.keyState(.combinedSessionState, key: $0) || CGEventSource.keyState(.hidSystemState, key: $0) })
    }
}

/// Keys another app seems to be using, as each place words it, and the chords waiting on "Use anyway".
@MainActor @Observable final class ShortcutInUse {
    static let shared = ShortcutInUse()
    /// The chord each action's recorder saw taken: what "Use anyway" saves.
    var chords: [ShortcutSettings.Action: Shortcut] = [:]

    static func settings(_ shortcut: Shortcut) -> String { "Another app is using \(shortcut.label). Choose other keys." }
    static func onboarding(_ shortcut: Shortcut) -> String { "Another app is using \(shortcut.label). Press other keys." }

    /// The chord "Use anyway" may save beside `error`: only the one that error names. Any other error on screen
    /// (a later choice refused, say) offers nothing.
    static func useAnyway(_ pending: Shortcut?, error: String?, message: (Shortcut) -> String) -> Shortcut? {
        guard let pending, error == message(pending) else { return nil }
        return pending
    }

    static func announce(_ message: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
}

extension Notification.Name {
    /// A shortcut row's "Use anyway": the object is the action whose recorder saves the chord it saw taken.
    static let shortcutUseAnyway = Notification.Name("ShortcutUseAnyway")
}
