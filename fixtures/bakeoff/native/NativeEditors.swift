import AppKit
import SwiftUI

extension NSAttributedString.Key { static let bakeoffLabel = NSAttributedString.Key("bakeoffLabel") }

/// The editors, by toolkit name. SwiftUI ones are in NativeSwiftUI.swift, the custom view in NativeCustom.swift.
@MainActor enum Editors {
    static func make(_ spec: Case) -> Editor? {
        switch spec.toolkit {
        case "appkit-tk1": TextViewEditor(spec, textKit2: false)
        case "appkit-tk2": TextViewEditor(spec, textKit2: true)
        case "appkit-field": FieldEditor(spec)
        case "swiftui-editor", "swiftui-field", "swiftui-rich": SwiftUIEditor(spec)
        case "custom-opaque": CustomEditor(spec)
        case "appkit-secure": FieldEditor(spec, secure: true)
        case "appkit-readonly": TextViewEditor(spec, textKit2: true, editable: false)
        default: nil
        }
    }

    static func paragraphStyle(_ spec: Case) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        if spec.rtl { style.baseWritingDirection = .rightToLeft; style.alignment = .right }
        return style
    }

    /// A rounded chip or an emoji drawn as an image, the way native composers show atoms.
    static func image(_ label: String, chip: Bool, size: CGFloat) -> NSImage {
        let font = NSFont.systemFont(ofSize: size)
        let string = NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: chip ? NSColor.systemBlue : NSColor.labelColor])
        let bounds = string.size()
        let image = NSImage(size: NSSize(width: ceil(bounds.width) + (chip ? 8 : 0), height: ceil(bounds.height)))
        image.lockFocus()
        if chip {
            NSColor.systemBlue.withAlphaComponent(0.12).setFill()
            NSBezierPath(roundedRect: NSRect(origin: .zero, size: image.size), xRadius: 4, yRadius: 4).fill()
        }
        string.draw(at: NSPoint(x: chip ? 4 : 0, y: 0))
        image.unlockFocus()
        return image
    }

    /// The draft as attributed text: mentions and emoji images as attachments when `attachments`,
    /// as plain text otherwise. Each attachment carries its label, for text().
    static func attributed(_ spec: Case, attachments: Bool) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: spec.fontSize)
        let base: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: paragraphStyle(spec), .foregroundColor: NSColor.textColor]
        let result = NSMutableAttributedString()
        for (index, paragraph) in spec.paragraphs.enumerated() {
            if index > 0 { result.append(NSAttributedString(string: "\n", attributes: base)) }
            for segment in paragraph {
                if attachments, segment.mention != nil || segment.emoji != nil {
                    let attachment = NSTextAttachment()
                    attachment.image = image(segment.label, chip: segment.mention != nil, size: spec.fontSize)
                    attachment.bounds = NSRect(x: 0, y: font.descender, width: attachment.image!.size.width, height: attachment.image!.size.height)
                    let piece = NSMutableAttributedString(attachment: attachment)
                    piece.addAttributes(base.merging([.bakeoffLabel: segment.label]) { a, _ in a }, range: NSRange(location: 0, length: piece.length))
                    result.append(piece)
                } else {
                    result.append(NSAttributedString(string: segment.label, attributes: base))
                }
            }
        }
        return result
    }

    /// Text by the shared rules: an attachment reads as its label.
    static func text(_ string: NSAttributedString) -> String {
        var out = ""
        string.enumerateAttribute(.bakeoffLabel, in: NSRange(location: 0, length: string.length)) { label, range, _ in
            out += (label as? String) ?? (string.string as NSString).substring(with: range)
        }
        return out
    }

    /// A draft offset as a storage offset (an attachment is one character), and back.
    static func storageOffset(_ string: NSAttributedString, _ offset: Int) -> Int {
        var remaining = offset, at = 0
        while at < string.length, remaining > 0 {
            if let label = string.attribute(.bakeoffLabel, at: at, effectiveRange: nil) as? String { remaining -= (label as NSString).length }
            else { remaining -= 1 }
            at += 1
        }
        return at
    }

    static func draftOffset(_ string: NSAttributedString, _ offset: Int) -> Int {
        var total = 0
        for at in 0..<min(offset, string.length) {
            total += (string.attribute(.bakeoffLabel, at: at, effectiveRange: nil) as? String).map { ($0 as NSString).length } ?? 1
        }
        return total
    }

    static func counts(_ string: NSAttributedString) -> [String: Int] {
        var chips = 0, images = 0
        string.enumerateAttribute(.bakeoffLabel, in: NSRange(location: 0, length: string.length)) { label, _, _ in
            guard let label = label as? String else { return }
            if label.hasPrefix("@") { chips += 1 } else { images += 1 }
        }
        return ["chips": chips, "images": images]
    }
}

/// NSTextView in a scroll view, on TextKit 1 or 2: Notes, Mail's plain composer, most native composers.
@MainActor final class TextViewEditor: NSObject, Editor, NSTextViewDelegate {
    let view: NSView
    let textView: NSTextView
    var onChange: (() -> Void)?

    init(_ spec: Case, textKit2: Bool, editable: Bool = true) {
        let scroll = NSScrollView()
        textView = NSTextView(usingTextLayoutManager: textKit2)
        textView.isRichText = true
        textView.isEditable = editable
        textView.allowsUndo = true
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        textView.typingAttributes = [.font: NSFont.systemFont(ofSize: spec.fontSize), .paragraphStyle: Editors.paragraphStyle(spec)]
        textView.textStorage?.setAttributedString(Editors.attributed(spec, attachments: true))
        textView.setAccessibilityLabel("Message")
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        textView.drawsBackground = false
        view = scroll
        super.init()
        textView.delegate = self
    }

    func textDidChange(_ notification: Notification) { onChange?() }
    func text() -> String { Editors.text(textView.attributedString()) }
    func counts() -> [String: Int] { Editors.counts(textView.attributedString()) }
    func focus() { textView.window?.makeFirstResponder(textView) }

    func select(_ start: Int, _ end: Int) {
        let string = textView.attributedString(), from = Editors.storageOffset(string, start)
        textView.setSelectedRange(NSRange(location: from, length: Editors.storageOffset(string, end) - from))
        textView.scrollRangeToVisible(textView.selectedRange())
    }

    func caret() -> Int? {
        let range = textView.selectedRange()
        return range.length == 0 ? Editors.draftOffset(textView.attributedString(), range.location) : nil
    }

    func insert(_ string: String) { textView.insertText(string, replacementRange: textView.selectedRange()) }

    /// The storage rebuilt from the app's copy of it, as model-driven apps do; the selection kept.
    func rerender() {
        let range = textView.selectedRange(), copy = NSAttributedString(attributedString: textView.attributedString())
        textView.textStorage?.setAttributedString(copy)
        textView.setSelectedRange(range)
    }
}

/// NSTextField, edited through the window's field editor: search boxes, forms, one-line chat inputs.
@MainActor final class FieldEditor: NSObject, Editor, NSTextFieldDelegate {
    let view: NSView
    let field: NSTextField
    var onChange: (() -> Void)?

    init(_ spec: Case, secure: Bool = false) {
        field = secure ? NSSecureTextField() : NSTextField()
        field.stringValue = spec.text
        field.font = .systemFont(ofSize: spec.fontSize)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.placeholderString = secure ? "Password" : "Message"
        if spec.rtl { field.baseWritingDirection = .rightToLeft; field.alignment = .right }
        view = field
        super.init()
        field.delegate = self
    }

    func controlTextDidChange(_ obj: Notification) { onChange?() }
    func text() -> String { field.currentEditor()?.string ?? field.stringValue }
    func counts() -> [String: Int] { ["chips": 0, "images": 0] }
    func focus() { field.window?.makeFirstResponder(field) }
    func select(_ start: Int, _ end: Int) { field.currentEditor()?.selectedRange = NSRange(location: start, length: end - start) }

    func caret() -> Int? {
        guard let range = field.currentEditor()?.selectedRange, range.length == 0 else { return nil }
        return range.location
    }

    func insert(_ string: String) {
        guard let editor = field.currentEditor() as? NSTextView else { return }
        editor.insertText(string, replacementRange: editor.selectedRange())
    }

    /// The value set again from the app's state, which ends and restarts the field editor's session.
    func rerender() {
        let range = field.currentEditor()?.selectedRange ?? NSRange(location: 0, length: 0), value = text()
        field.stringValue = value
        focus()
        field.currentEditor()?.selectedRange = range
    }
}
