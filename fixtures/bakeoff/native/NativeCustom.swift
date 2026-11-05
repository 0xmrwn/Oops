import AppKit

/// A view that draws and edits its own text through NSTextInputClient and shows Accessibility only a
/// group with no text, as GPU-drawn editors (Zed, terminals, games) do. Copy and paste work.
@MainActor final class OpaqueTextView: NSView, @preconcurrency NSTextInputClient {
    var string = "" { didSet { needsDisplay = true; onChange?() } }
    var selection = NSRange(location: 0, length: 0) { didSet { needsDisplay = true } }
    var marked = NSRange(location: NSNotFound, length: 0)
    var font = NSFont.systemFont(ofSize: 15)
    var onChange: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { "Editor" }

    override func draw(_ dirtyRect: NSRect) {
        let text = NSMutableAttributedString(string: string, attributes: [.font: font, .foregroundColor: NSColor.textColor])
        if selection.length > 0, NSMaxRange(selection) <= text.length {
            text.addAttribute(.backgroundColor, value: NSColor.selectedTextBackgroundColor, range: selection)
        }
        text.draw(in: bounds.insetBy(dx: 6, dy: 6))
    }

    override func keyDown(with event: NSEvent) { interpretKeyEvents([event]) }

    func replace(_ range: NSRange, with text: String) {
        string = (string as NSString).replacingCharacters(in: range, with: text)
        selection = NSRange(location: range.location + (text as NSString).length, length: 0)
        marked = NSRange(location: NSNotFound, length: 0)
    }

    @objc func copy(_ sender: Any?) {
        guard selection.length > 0 else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString((string as NSString).substring(with: selection), forType: .string)
    }

    @objc func paste(_ sender: Any?) {
        if let text = NSPasteboard.general.string(forType: .string) { replace(selection, with: text) }
    }

    @objc override func selectAll(_ sender: Any?) { selection = NSRange(location: 0, length: (string as NSString).length) }
    override func deleteBackward(_ sender: Any?) {
        if selection.length > 0 { replace(selection, with: "") }
        else if selection.location > 0 { replace(NSRange(location: selection.location - 1, length: 1), with: "") }
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? string as? String ?? ""
        replace(replacementRange.location == NSNotFound ? (marked.location != NSNotFound ? marked : selection) : replacementRange, with: text)
    }

    override func doCommand(by selector: Selector) {}
    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? string as? String ?? ""
        let range = marked.location != NSNotFound ? marked : selection
        self.string = (self.string as NSString).replacingCharacters(in: range, with: text)
        marked = NSRange(location: range.location, length: (text as NSString).length)
        selection = NSRange(location: range.location + selectedRange.location, length: 0)
    }

    func unmarkText() { marked = NSRange(location: NSNotFound, length: 0) }
    func selectedRange() -> NSRange { selection }
    func markedRange() -> NSRange { marked }
    func hasMarkedText() -> Bool { marked.location != NSNotFound }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        let clamped = NSIntersectionRange(range, NSRange(location: 0, length: (string as NSString).length))
        return NSAttributedString(string: (string as NSString).substring(with: clamped))
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        window?.convertToScreen(convert(NSRect(x: 6, y: 6, width: 1, height: font.pointSize + 4), to: nil)) ?? .zero
    }

    func characterIndex(for point: NSPoint) -> Int { 0 }
}

@MainActor final class CustomEditor: Editor {
    let view: NSView
    let text_: OpaqueTextView
    var onChange: (() -> Void)? { didSet { text_.onChange = onChange } }

    init(_ spec: Case) {
        text_ = OpaqueTextView()
        text_.font = .systemFont(ofSize: spec.fontSize)
        text_.string = spec.text
        view = text_
    }

    func text() -> String { text_.string }
    func counts() -> [String: Int] { ["chips": 0, "images": 0] }
    func focus() { view.window?.makeFirstResponder(text_) }
    func select(_ start: Int, _ end: Int) { text_.selection = NSRange(location: start, length: end - start) }
    func caret() -> Int? { text_.selection.length == 0 ? text_.selection.location : nil }
    func insert(_ string: String) { text_.replace(text_.selection, with: string) }
    func rerender() { text_.string = text_.string }
}
