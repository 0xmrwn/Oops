import AppKit

/// The pill's room in the text: it draws nothing, and the coordinator lays the pill's live view over it. (NSTextView
/// made a view provider for it but never loaded or placed its view.)
final class ChoiceAttachment: NSTextAttachment {
    /// What the pill says, which its room follows. Kept here, so a layout never depends on who asks and when.
    private(set) nonisolated(unsafe) var label = ""

    init(label: String = "") {
        self.label = label
        super.init(data: nil, ofType: nil)
        allowsTextAttachmentView = false
        image = NSImage(size: NSSize(width: 1, height: 1))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The width the text leaves for the pill: its own, and a margin either side.
    var reservedWidth: CGFloat { PillMetrics.width(label) + 2 * PillMetrics.margin }

    override func attachmentBounds(for attributes: [NSAttributedString.Key: Any], location: any NSTextLocation,
                                   textContainer: NSTextContainer?, proposedLineFragment: CGRect, position: CGPoint) -> CGRect {
        // Room in the font's own line box only: a pill reaching below the font's descent made its line 2 pt taller
        // than the others. The pill's view, laid over this room, is drawn its full height.
        let font = PillMetrics.font
        return CGRect(x: 0, y: font.descender, width: reservedWidth, height: font.ascender - font.descender)
    }

    /// Gives the pill the room for `label` and has the text around it lay out again. Laying the whole document out
    /// again asks nothing of an attachment whose character is unchanged, so the character's attachment is set anew.
    @MainActor func resize(to label: String, in text: NSTextView) {
        self.label = label
        guard let storage = text.textStorage else { return }
        let string = storage.string as NSString
        var search = NSRange(location: 0, length: string.length)
        storage.beginEditing()
        while true {
            let range = string.range(of: "\u{FFFC}", range: search)
            if range.location == NSNotFound { break }
            if storage.attribute(.attachment, at: range.location, effectiveRange: nil) as? ChoiceAttachment === self {
                storage.removeAttribute(.attachment, range: range)
                storage.addAttribute(.attachment, value: self, range: range)
            }
            search = NSRange(location: range.upperBound, length: string.length - range.upperBound)
        }
        storage.endEditing()
    }
}
