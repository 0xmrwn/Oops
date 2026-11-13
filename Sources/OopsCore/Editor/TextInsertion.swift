import Foundation

/// Why an insert wrote nothing.
public enum InsertRefusal: String, Error, Equatable, Sendable {
    /// No text was given.
    case empty
    /// Oops isn't allowed in Accessibility.
    case permission
    /// Nothing that takes text has focus.
    case noEditor
    /// A terminal or a password manager (`EditorApplicationPolicy.denied`).
    case appDenied
    /// An app turned off in Settings.
    case appTurnedOff
    /// A password or code field.
    case secureField
    case readOnly
    /// An input method is composing in the field.
    case composing
    /// The shortcut's keys were never let go.
    case keysHeld
    /// Focus left the field before the text was written.
    case focusMoved
    /// The clipboard couldn't be saved, or changed while it was.
    case clipboard
    case cancelled
}

public enum InsertOutcome: Equatable, Sendable {
    /// The field reads the text where the caret or selection was.
    case inserted
    /// The text was pasted, but the field can't be read or doesn't read as expected.
    case unconfirmed
    /// Nothing was written.
    case refused(InsertRefusal)
}

/// The rules of writing text at the caret that need no editor to check.
public enum TextInsertion {
    /// Insert follows Fix's application scope.
    public static func refusal(for verdict: EditorApplicationPolicy.Verdict) -> InsertRefusal? {
        switch verdict {
        case .accepted: nil
        case .denied: .appDenied
        case .turnedOff: .appTurnedOff
        case .unknown: .noEditor
        }
    }

    /// Whether the focused field holds a secret, by the checks Fix reads a draft under: a secure field,
    /// one whose labels say password or code (a multi-line text area is never one), or one showing only
    /// mask characters. `readable` is false for an editor that exposes no text, where the labels are all there is.
    public static func holdsSecret(role: String, subrole: String?, descriptions: [String], value: String?, readable: Bool) -> Bool {
        if subrole == "AXSecureTextField" { return true }
        guard readable else { return SensitiveField.matches(descriptions) }
        guard role != "AXTextArea" else { return false }
        return SensitiveField.matches(descriptions) || value.map(SensitiveField.isMasked) == true
    }

    /// The field's text once `text` replaces `selection` (a caret when empty), in UTF-16 units; nil when
    /// the selection lies outside `value`. A value that is only the field's placeholder counts as empty.
    public static func result(of text: String, in value: String, replacing selection: NSRange, placeholders: [String] = []) -> String? {
        if CorrectionPolicy.isPlaceholder(value, hints: placeholders) { return text }
        guard selection.location >= 0, selection.length >= 0, NSMaxRange(selection) <= value.utf16.count else { return nil }
        return (value as NSString).replacingCharacters(in: selection, with: text)
    }
}
