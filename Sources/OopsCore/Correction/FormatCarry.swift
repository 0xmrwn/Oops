import Foundation

/// Which original character each pasted character takes its formatting from, so a fix inside a bold
/// word stays bold and a comma added after one doesn't turn bold. Characters both sides share at either
/// end keep their own; the changed middle maps across proportionally; an insertion takes the formatting
/// of the neighbour most like it (punctuation beside punctuation or a space, a letter beside a letter).
public enum FormatCarry {
    /// Runs of `replacement` (UTF-16 ranges, in order, covering it) with the UTF-16 offset in `original`
    /// of the character whose formatting each run takes. Empty when `original` is.
    public static func sources(original: String, replacement: String) -> [(range: NSRange, source: Int)] {
        let a = graphemes(original), b = graphemes(replacement)
        guard !a.isEmpty else { return [] }
        var prefix = 0
        while prefix < min(a.count, b.count), sameText(a[prefix].text, b[prefix].text) { prefix += 1 }
        var suffix = 0
        while suffix < min(a.count, b.count) - prefix, sameText(a[a.count - 1 - suffix].text, b[b.count - 1 - suffix].text) { suffix += 1 }
        let middle = a.count - prefix - suffix, inserted = b.count - prefix - suffix
        var runs: [(range: NSRange, source: Int)] = []
        for (index, grapheme) in b.enumerated() {
            let from: Int
            if index < prefix {
                from = index
            } else if index >= b.count - suffix {
                from = a.count - (b.count - index)
            } else if middle > 0 {
                from = prefix + (index - prefix) * middle / inserted
            } else {
                from = neighbour(of: grapheme.text, before: prefix - 1, after: prefix, in: a)
            }
            let source = a[from].range.location
            if let last = runs.last, last.source == source, NSMaxRange(last.range) == grapheme.range.location {
                runs[runs.count - 1].range.length += grapheme.range.length
            } else {
                runs.append((grapheme.range, source))
            }
        }
        return runs
    }

    /// The original character an inserted one sits beside whose kind (word character or not) matches it.
    private static func neighbour(of inserted: String, before: Int, after: Int, in a: [(text: String, range: NSRange)]) -> Int {
        let word = isWord(inserted)
        let candidates = [before, after].filter { a.indices.contains($0) }
        return candidates.first { isWord(a[$0].text) == word } ?? candidates[0]
    }

    static func graphemes(_ text: String) -> [(text: String, range: NSRange)] {
        var result: [(text: String, range: NSRange)] = [], offset = 0
        for character in text {
            let length = character.utf16.count
            result.append((String(character), NSRange(location: offset, length: length)))
            offset += length
        }
        return result
    }

    static func isWord(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy(CharacterSet.alphanumerics.contains)
    }
}

extension TextEdits {
    /// The edit without whole words it leaves untouched at either end, where a space or punctuation
    /// separates them from what it changes: "handy, evriday," → "handy every day." becomes ", evriday,"
    /// → " every day.". Typed text takes the formatting of the first character it replaces, so typing the
    /// whole span over a bold word would make the fix bold, or drop the bold. Nil when nothing trims or
    /// either side would be left empty.
    public static func besideWords(of edit: TextChange) -> TextChange? {
        let a = FormatCarry.graphemes(edit.original), b = FormatCarry.graphemes(edit.replacement)
        var prefix = 0
        while prefix < min(a.count, b.count), sameText(a[prefix].text, b[prefix].text) { prefix += 1 }
        // Back to the end of a whole word followed, on both sides, by something that isn't a word character.
        while prefix > 0, !(FormatCarry.isWord(a[prefix - 1].text) && boundary(a, prefix) && boundary(b, prefix)) { prefix -= 1 }
        var suffix = 0
        while suffix < min(a.count, b.count) - prefix, sameText(a[a.count - 1 - suffix].text, b[b.count - 1 - suffix].text) { suffix += 1 }
        while suffix > 0, !(FormatCarry.isWord(a[a.count - suffix].text) && boundary(a, a.count - suffix - 1)
                                && boundary(b, b.count - suffix - 1)) { suffix -= 1 }
        guard prefix + suffix > 0, a.count - prefix - suffix > 0, b.count - prefix - suffix > 0 else { return nil }
        let lead = a[..<prefix].reduce(0) { $0 + $1.range.length }
        let originalEnd = a.count - suffix, replacementEnd = b.count - suffix
        let original = a[prefix..<originalEnd].map(\.text).joined(), replacement = b[prefix..<replacementEnd].map(\.text).joined()
        return TextChange(location: edit.location + lead, original: original, replacement: replacement, rule: edit.rule)
    }

    /// Whether the character at `index` exists and isn't a word character.
    private static func boundary(_ characters: [(text: String, range: NSRange)], _ index: Int) -> Bool {
        characters.indices.contains(index) && !FormatCarry.isWord(characters[index].text)
    }
}
