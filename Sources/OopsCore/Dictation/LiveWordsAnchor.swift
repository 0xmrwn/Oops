import CoreGraphics

/// Decides where one dictation's live words go: at the caret only when Settings asks for it, the field gives a
/// caret worth drawing beside, and the words can be drawn there as the field's own text would be; else in the drop.
public enum LiveWordsAnchor {
    /// `.drop` when `place` is the drop; when there is no geometry or caret; when the caret is shorter than 8 pt,
    /// taller than 80 pt or wider than 10 pt (Chromium's placeholder and whole-editor answers); when it lies outside
    /// the field's frame; or when less than `minimumWidth` is left from the caret to the field's right edge (the
    /// window's when the field's frame is unknown). Also `.drop` when the field tells nothing of its text at the
    /// caret (no caret position, or a selection), and when text follows the caret on its line, which the words would
    /// cover. Otherwise the caret, with that room. Few fields tell both a font and a colour (AppKit tells the font,
    /// Chromium the colour and size), so neither is required: the drawing fills in what is missing.
    public static func target(_ place: DictationLiveWordsPlace, geometry: CapsulePlacement.Geometry?, style: CaretStyle?,
                              minimumWidth: CGFloat = 120) -> LiveWordsTarget {
        guard let style, !style.followed else { return .drop }
        // The caret as placement trusts it: AppKit puts a line-end caret on the line above, which the character
        // before it corrects.
        guard place == .text, let geometry, let caret = CapsulePlacement.caret(geometry, within: geometry.element ?? geometry.window),
              (8 ... 80).contains(caret.height), caret.width <= 10 else { return .drop }
        if let element = geometry.element, !element.insetBy(dx: -2, dy: -2).contains(CGPoint(x: caret.midX, y: caret.midY)) {
            return .drop
        }
        guard let edge = (geometry.element ?? geometry.window)?.maxX else { return .drop }
        let room = edge - caret.maxX
        return room >= minimumWidth ? .caret(caret, width: room) : .drop
    }
}
