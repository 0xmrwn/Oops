import Foundation

/// How the dictation shortcut's presses and releases start and end a recording. The raw values are what
/// Settings stores.
public enum DictationMode: String, CaseIterable, Sendable, Codable {
    /// Hold to talk; a tap shorter than the hold threshold keeps recording until the next press.
    case holdOrTap
    /// Hold to talk; a double tap keeps recording until the next press, and a lone quick tap writes
    /// nothing.
    case holdOrDoubleTap
    /// Hold to talk: every release ends the recording.
    case holdOnly
    /// Press to start, press again to end.
    case tapOnly
}
