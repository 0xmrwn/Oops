import Carbon

/// Escape cancels a recording, held or latched, and is registered only while one runs, as Handy registers
/// its cancel shortcut (`transcription_coordinator.rs` at 73cc857). Neither Hex nor Handy covers the held
/// case: Escape pressed during a hold arrives with the shortcut's modifiers down, so it is registered with
/// them too. Not with ⌥⌘, though: ⌥⌘⎋ is Force Quit, which must always reach the system.
public enum DictationEscape {
    /// Escape, whatever the layout.
    public static let keyCode: UInt32 = 53
    static let forceQuit = UInt32(optionKey | cmdKey)

    /// The Carbon modifier sets Escape is registered with: none while nothing records; plain Escape for a
    /// latched recording; while the shortcut (`shortcut`, its Carbon modifiers) is held, also Escape with
    /// those modifiers, unless they hold ⌥⌘.
    public static func modifiers(shortcut: UInt32?, recording: Bool, locked: Bool) -> [UInt32] {
        guard recording else { return [] }
        guard !locked, let shortcut, shortcut != 0, shortcut & forceQuit != forceQuit else { return [0] }
        return [0, shortcut]
    }
}
