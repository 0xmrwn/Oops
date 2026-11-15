import CoreGraphics

/// Where live words appear. The raw values are what Settings stores.
public enum DictationLiveWordsPlace: String, CaseIterable, Sendable {
    /// On the shelf the drop opens beside its capsule; the text field is untouched until the end.
    case drop
    /// At the caret, as ghost text in the field's own font and colour, through the highlight overlay.
    case text
}

/// Where one dictation's words go, from the setting and the field's geometry read as the drop came up.
public enum LiveWordsTarget: Equatable, Sendable {
    case drop
    /// The caret in AX points (top-left, global), and how wide the words may run before the field's edge.
    case caret(CGRect, width: CGFloat)
}
