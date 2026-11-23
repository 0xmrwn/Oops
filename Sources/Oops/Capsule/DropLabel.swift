import AppKit

/// Measuring and fitting the drop's label, whose parts (`6 fixes · 5.7s`) are drawn apart by a hairline `divider` wide.
enum DropLabel {
    static func measure(_ text: String, _ font: NSFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width.rounded(.up)
    }

    static func width(_ parts: [String], font: NSFont, divider: CGFloat) -> CGFloat {
        parts.map { measure($0, font) }.reduce(0, +) + CGFloat(max(0, parts.count - 1)) * divider
    }

    /// The parts cut to fit `room` rather than run past the glass: the words in the first part lose whole words
    /// from their end behind an ellipsis, a single long word its letters; a count or a timing after them stays whole.
    static func fitted(_ parts: [String], room: CGFloat, font: NSFont, divider: CGFloat) -> [String] {
        guard let first = parts.first, width(parts, font: font, divider: divider) > room else { return parts }
        let rest = Array(parts.dropFirst())
        func fits(_ head: String) -> Bool { width([head + "…"] + rest, font: font, divider: divider) <= room }
        var words = first.split(separator: " ").map(String.init)
        while words.count > 1 {
            words.removeLast()
            if fits(words.joined(separator: " ")) { return [words.joined(separator: " ") + "…"] + rest }
        }
        var word = words.first ?? ""
        while !word.isEmpty, !fits(word) { word.removeLast() }
        return [word + "…"] + rest
    }
}
