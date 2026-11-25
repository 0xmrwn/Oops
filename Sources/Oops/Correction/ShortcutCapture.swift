import AppKit
import Carbon
import OSLog

/// What a key-down does to a shortcut being recorded, in Settings and in onboarding alike. The chord is complete
/// on a key-down that is not a repeat, with ⌃, ⌥ or ⌘ held: it is that key with the modifiers that key-down
/// carries, never ones seen held before it, so the saved shortcut is the keys pressed together.
enum ShortcutCapture: Equatable {
    /// Escape alone stops recording.
    case cancel
    /// A repeat of a key already down completes nothing: a chord's own press may have gone to another app.
    case ignore
    /// No ⌃, ⌥ or ⌘: Shift alone would take a letter from every text field.
    case refuse
    case record(Shortcut)

    init(keyCode: UInt16, flags: NSEvent.ModifierFlags, isRepeat: Bool) {
        let modifiers = Shortcut.modifiers(flags)
        if keyCode == 53, modifiers == 0 { self = .cancel }
        else if isRepeat { self = .ignore }
        else if modifiers & UInt32(controlKey | optionKey | cmdKey) == 0 { self = .refuse }
        else { self = .record(Shortcut(keyCode: UInt32(keyCode), modifiers: modifiers)) }
    }

    /// Each key-down a recorder hears, with the process that posted it: another app's synthetic key, or a key it
    /// swallowed, is what makes a recorded shortcut differ from the keys pressed.
    func log(_ action: ShortcutSettings.Action, event: NSEvent) {
        let source = event.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID) ?? -1
        Self.logger.notice("""
            recorder action=\(action.rawValue, privacy: .public) key=\(event.keyCode, privacy: .public) \
            modifiers=\(Shortcut.modifiers(event.modifierFlags), privacy: .public) repeat=\(event.isARepeat, privacy: .public) \
            source_pid=\(source, privacy: .public) outcome=\(String(describing: self), privacy: .public)
            """)
    }

    private static let logger = Logger(subsystem: "dev.0xmrwn.oops", category: "Shortcuts")
}
