import AppKit
import ApplicationServices
import OSLog
import OopsCore

/// A fix keeps the formatting of the words it touches. Spans stay whole words, which keeps editors' smart
/// paste predictable, so a span can cover a bold word beside the fix: pasted as plain text the editor drops
/// the bold (Messages) or styles the whole span like its first character (typing in Chromium).
extension EditorAccess {
    /// RTF for `replacement` with each character formatted like the one it replaces, when the editor
    /// reports the span's formatting and some of it is bold, italic, underlined or struck through.
    /// Nil leaves a plain paste: the span is plain, holds a link, or its formatting can't be read.
    nonisolated func richInput(_ element: AXUIElement, _ range: NSRange, original: String, replacement: String) -> Data? {
        var value = CFRange(location: range.location, length: range.length)
        guard let parameter = AXValueCreate(.cfRange, &value) else { return nil }
        let read: NSAttributedString? = AccessibilityExecution.perform(for: element) {
            var result: CFTypeRef?
            return AXUIElementCopyParameterizedAttributeValue(element, kAXAttributedStringForRangeParameterizedAttribute as CFString,
                                                              parameter, &result) == .success ? result as? NSAttributedString : nil
        }
        guard let read, sameText(read.string, original) else { return nil }
        // RTF can't carry a link Accessibility reports as an element: a plain paste keeps the editor's link.
        var linked = false
        read.enumerateAttribute(NSAttributedString.Key("AXLink"), in: NSRange(location: 0, length: read.length)) { value, _, stop in
            if value != nil { linked = true; stop.pointee = true }
        }
        guard !linked else { return nil }
        let formatted = Self.appKitFormatting(read)
        guard Self.isFormatted(formatted) else { return nil }
        let rich = NSMutableAttributedString(string: replacement)
        for run in FormatCarry.sources(original: original, replacement: replacement) {
            rich.setAttributes(formatted.attributes(at: run.source, effectiveRange: nil), range: run.range)
        }
        Self.selectionLog.info("paste_rich length=\(replacement.utf16.count, privacy: .public)")
        return rich.rtf(from: NSRange(location: 0, length: rich.length))
    }

    /// The edit narrowed off untouched whole words at its ends, once the web editor holds that narrower
    /// selection by its own copy; nil once the whole span is selected and held again instead.
    func narrowed(_ edit: TextChange, element: AXUIElement, strategy: CaptureStrategy, clipboard: ClipboardLease,
                  validate: () throws -> Void, reselectWhole: () -> AXError) throws -> TextChange? {
        guard let inner = TextEdits.besideWords(of: edit) else { return nil }
        do {
            try SelectionConfirmation.require(inner.range, write: { self.select(element, inner.range, strategy) },
                                              read: { self.selection(element, strategy) }, validate: validate)
            if try editorHolds(inner.original, clipboard: clipboard, reselect: { _ = self.select(element, inner.range, strategy) },
                               validate: validate) {
                Self.selectionLog.info("narrowed_beside_words")
                return inner
            }
        } catch is SelectionConfirmation.Failure {}
        _ = reselectWhole()
        guard try editorHolds(edit.original, clipboard: clipboard, reselect: { _ = reselectWhole() }, validate: validate)
        else { throw EditorKeptSelection() }
        return nil
    }

    /// Accessibility's font, underline and strikethrough as AppKit attributes. No colour: an editor's own
    /// text colour (light in dark mode) applies to what's pasted.
    static func appKitFormatting(_ read: NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString(string: read.string)
        read.enumerateAttributes(in: NSRange(location: 0, length: read.length)) { attributes, range, _ in
            var converted: [NSAttributedString.Key: Any] = [:]
            // Editors' own markers count too: Messages marks bold with `__kIMTextBoldAttributeName` beside a Semibold font.
            // A marker reported as false (`AXFontBold = 0`) is no formatting.
            let marked = { (word: String) in
                attributes.contains { key, value in
                    key.rawValue.contains(word) && key.rawValue != "AXFont" && ((value as? NSNumber)?.boolValue ?? true)
                }
            }
            if let font = attributes[NSAttributedString.Key("AXFont")] as? [String: Any] {
                converted[.font] = Self.font(name: font["AXFontName"] as? String ?? "", size: (font["AXFontSize"] as? NSNumber)?.doubleValue ?? 13,
                                             bold: marked("Bold"), italic: marked("Italic"))
            }
            if (attributes[NSAttributedString.Key("AXUnderline")] as? NSNumber)?.boolValue == true || marked("UnderlineAttribute") {
                converted[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            if (attributes[NSAttributedString.Key("AXStrikethrough")] as? NSNumber)?.boolValue == true || marked("StrikethroughAttribute") {
                converted[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            result.setAttributes(converted, range: range)
        }
        return result
    }

    /// The named font, or the system font of that size: editors report private names (".SFNS-Semibold")
    /// that `NSFont(name:)` may not resolve. A weight from Semibold up, or a marker, counts as bold: the
    /// paste carries the bold trait, which editors map onto their own bold.
    static func font(name: String, size: Double, bold: Bool = false, italic: Bool = false) -> NSFont {
        let lower = name.lowercased()
        var font = NSFont(name: name, size: size) ?? NSFont.systemFont(ofSize: size)
        let weight = (font.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any])?[.weight] as? Double ?? 0
        let heavy = bold || weight >= NSFont.Weight.semibold.rawValue || ["semibold", "bold", "heavy", "black"].contains(where: lower.contains)
        if heavy, !font.fontDescriptor.symbolicTraits.contains(.bold) { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
        if heavy, !font.fontDescriptor.symbolicTraits.contains(.bold) { font = NSFont.boldSystemFont(ofSize: size) }
        if italic || lower.contains("italic") || lower.contains("oblique") { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        return font
    }

    static func isFormatted(_ text: NSAttributedString) -> Bool {
        var formatted = false
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, _, stop in
            let traits = (attributes[.font] as? NSFont)?.fontDescriptor.symbolicTraits ?? []
            if traits.contains(.bold) || traits.contains(.italic) || attributes[.underlineStyle] != nil || attributes[.strikethroughStyle] != nil {
                formatted = true; stop.pointee = true
            }
        }
        return formatted
    }
}
