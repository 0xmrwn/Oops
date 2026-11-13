import Foundation

/// Where the dictation drop appears. The raw values are what Settings stores.
public enum DictationDropPosition: String, CaseIterable, Sendable {
    /// By the focused text field, as Fix's drop is.
    case anchored
    /// Centred at the top of the screen, below the menu bar and the notch.
    case top
    /// Centred at the bottom of the screen, above the Dock.
    case bottom

    /// With no focused field there is no spot by the text, so `anchored` becomes the bottom of the screen.
    public func resolved(hasAnchor: Bool) -> DictationDropPosition {
        self == .anchored && !hasAnchor ? .bottom : self
    }
}
