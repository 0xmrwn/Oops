import AppKit
import OopsCore

extension NSAttributedString.Key {
    /// Marks the characters of a skill's name in the instruction (the sigil included).
    static let oopsSkillToken = NSAttributedString.Key("oops.skillToken")
}

/// A skill the instruction names is drawn as a token: its words over a quiet rounded highlight, in the neutral tint the
/// choice's pill has. The words stay ordinary characters, so the person edits, selects and deletes them as any others.
enum SkillTokens {
    /// Marks the known skills' mentions in `storage` and unmarks what no longer is one; with no names, every token goes.
    /// Returns whether anything changed.
    @discardableResult
    static func apply(to storage: NSTextStorage, names: [String]) -> Bool {
        let wanted = names.isEmpty ? [] : ClaudeSkills.tokenRanges(in: storage.string, known: names)
        var marked: [NSRange] = []
        storage.enumerateAttribute(.oopsSkillToken, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if value != nil { marked.append(range) }
        }
        guard marked != wanted else { return false }
        storage.beginEditing()
        for range in marked { storage.removeAttribute(.oopsSkillToken, range: range) }
        for range in wanted { storage.addAttribute(.oopsSkillToken, value: true, range: range) }
        storage.endEditing()
        return true
    }
}

/// Gives the paragraphs that hold a token a fragment which draws the highlight; every other paragraph keeps the
/// system's.
final class SkillTokenLayout: NSObject, NSTextLayoutManagerDelegate {
    func textLayoutManager(_ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: any NSTextLocation,
                           in textElement: NSTextElement) -> NSTextLayoutFragment {
        if let paragraph = textElement as? NSTextParagraph, SkillTokenFragment.tokens(in: paragraph.attributedString).isEmpty == false {
            return SkillTokenFragment(textElement: textElement, range: textElement.elementRange)
        }
        return NSTextLayoutFragment(textElement: textElement, range: textElement.elementRange)
    }
}

/// A paragraph's layout with a rounded highlight drawn behind each token before its text.
final class SkillTokenFragment: NSTextLayoutFragment {
    /// How far the highlight reaches past the words, and past the font's own line box.
    private static let side: CGFloat = 2, rise: CGFloat = 2

    static func tokens(in text: NSAttributedString) -> [NSRange] {
        var ranges: [NSRange] = []
        text.enumerateAttribute(.oopsSkillToken, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if value != nil { ranges.append(range) }
        }
        return ranges
    }

    /// The highlight is drawn outside the words' own bounds.
    override var renderingSurfaceBounds: CGRect {
        super.renderingSurfaceBounds.insetBy(dx: -(Self.side + 1), dy: -(Self.rise + 1))
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        if let paragraph = textElement as? NSTextParagraph {
            context.saveGState()
            context.setFillColor(NSColor.labelColor.withAlphaComponent(0.14).cgColor)
            for token in Self.tokens(in: paragraph.attributedString) {
                for line in textLineFragments {
                    let part = NSIntersectionRange(token, line.characterRange)
                    guard part.length > 0 else { continue }
                    let bounds = line.typographicBounds
                    let start = bounds.minX + line.locationForCharacter(at: part.location).x
                    let end = bounds.minX + line.locationForCharacter(at: part.upperBound).x
                    guard let font = line.attributedString.attribute(.font, at: part.location, effectiveRange: nil) as? NSFont else { continue }
                    let baseline = point.y + bounds.minY + line.glyphOrigin.y
                    let rect = CGRect(x: point.x + start - Self.side, y: baseline - font.ascender - Self.rise,
                                      width: end - start + 2 * Self.side, height: font.ascender - font.descender + 2 * Self.rise)
                    context.addPath(CGPath(roundedRect: rect, cornerWidth: rect.height / 2, cornerHeight: rect.height / 2, transform: nil))
                    context.fillPath()
                }
            }
            context.restoreGState()
        }
        super.draw(at: point, in: context)
    }
}
