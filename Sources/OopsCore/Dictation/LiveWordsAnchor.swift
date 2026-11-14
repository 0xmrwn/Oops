import CoreGraphics

/// Decides where one dictation's live words go: at the caret only when Settings asks for it and the field gives a
/// caret worth drawing beside, else in the drop.
public enum LiveWordsAnchor {
    /// `.drop` when `place` is the drop; when there is no geometry or caret; when the caret is shorter than 8 pt,
    /// taller than 80 pt or wider than 10 pt (Chromium's placeholder and whole-editor answers); when it lies outside
    /// the field's frame; or when less than `minimumWidth` is left from the caret to the field's right edge (the
    /// window's when the field's frame is unknown). Otherwise the caret, with that room.
    public static func target(_ place: DictationLiveWordsPlace, geometry: CapsulePlacement.Geometry?,
                              minimumWidth: CGFloat = 120) -> LiveWordsTarget {
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
