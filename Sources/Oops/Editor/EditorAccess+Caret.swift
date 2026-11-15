import AppKit
import ApplicationServices
import OopsCore

/// What a dictation reads of the focused field as its drop comes up: where the caret is, and how the field
/// draws the text around it, so live words can be drawn there as that text would be.
extension EditorAccess {
    func focusedCaret() throws -> (geometry: CapsulePlacement.Geometry, style: CaretStyle?) {
        guard AXIsProcessTrusted() else { throw CorrectionError.message("Allow Oops in \(AccessibilityPermission.paneName) first.") }
        let element = try focusedWaking()
        return (geometry(element), caretStyle(element))
    }

    /// Nil when the field gives no caret position, or holds a selection: there is no one place the words continue.
    nonisolated func caretStyle(_ element: AXUIElement) -> CaretStyle? {
        guard let selection = range(element), selection.length == 0 else { return nil }
        let at = selection.location
        func first(_ range: NSRange) -> Unicode.Scalar? { rangeString(element, range)?.unicodeScalars.first }
        let before = at > 0 ? first(NSRange(location: at - 1, length: 1)) : nil, after = first(NSRange(location: at, length: 1))
        func breaks(_ scalar: Unicode.Scalar?) -> Bool { scalar.map(CharacterSet.newlines.contains) ?? true }
        var style = CaretStyle(followed: !breaks(after), spaced: before.map { !CharacterSet.whitespacesAndNewlines.contains($0) } ?? false)
        // Typing continues the character before the caret; at the start of a line, the one after it.
        let sample = breaks(before) ? NSRange(location: at, length: 1) : NSRange(location: at - 1, length: 1)
        guard let read = attributedString(element, sample), read.length > 0 else { return style }
        let attributes = read.attributes(at: 0, effectiveRange: nil)
        if let font = attributes[NSAttributedString.Key("AXFont")] as? [String: Any] {
            // AppKit names the font; Chromium gives a size alone, or a family.
            style.fontName = font["AXFontName"] as? String ?? font["AXFontFamily"] as? String
            style.fontSize = (font["AXFontSize"] as? NSNumber)?.doubleValue
        }
        if let value = attributes[NSAttributedString.Key("AXForegroundColor")], CFGetTypeID(value as CFTypeRef) == CGColor.typeID,
           let space = CGColorSpace(name: CGColorSpace.sRGB),
           let rgb = (value as! CGColor).converted(to: space, intent: .defaultIntent, options: nil)?.components, rgb.count >= 3 {
            style.color = SIMD3(Double(rgb[0]), Double(rgb[1]), Double(rgb[2]))
        }
        return style
    }

    nonisolated func attributedString(_ element: AXUIElement, _ range: NSRange) -> NSAttributedString? {
        var value = CFRange(location: range.location, length: range.length)
        guard let parameter = AXValueCreate(.cfRange, &value) else { return nil }
        return AccessibilityExecution.perform(for: element) {
            var result: CFTypeRef?
            return AXUIElementCopyParameterizedAttributeValue(element, kAXAttributedStringForRangeParameterizedAttribute as CFString,
                                                              parameter, &result) == .success ? result as? NSAttributedString : nil
        }
    }
}
