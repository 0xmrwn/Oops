import Foundation

/// A web field that mixes right-to-left and left-to-right text, as Chromium reports it: its text
/// (markers, selected text, and a contenteditable's value) can come in the order it lays the runs
/// out, a mention's "@" after the Latin name or a wrapped line's space moved, while selection ranges
/// keep counting in the order typed. Both hold the same characters, only moved. Oops keeps the draft
/// as typed and accepts a reading in display order; a copy of each selection confirms it before
/// pasting, and a paste is confirmed only when the reading can't hide where it went.
public enum DisplayOrder {
    /// Whether `shown` is `typed` with runs moved: the same characters in another order, in text that
    /// has right-to-left letters (nothing else is laid out in another order).
    public static func reordered(_ shown: String, of typed: String) -> Bool {
        !sameDraft(shown, typed) && rightToLeft(typed) && sameCharacters(shown, typed)
    }

    /// Whether `shown` is `typed` with runs moved only away from `span`: the text there, at its offsets,
    /// is exactly as typed (where a paste went, say).
    public static func reordered(_ shown: String, of typed: String, awayFrom span: NSRange) -> Bool {
        guard span.location != NSNotFound, reordered(shown, of: typed) else { return false }
        let a = shown as NSString, b = typed as NSString
        // Each moved run keeps its letters in order: laying text out moves spaces and punctuation (a mention's
        // "@", the space at a wrap) around runs, never letters within one (form and from differ).
        func letters(_ text: String) -> String { String(text.unicodeScalars.filter { $0.properties.isAlphabetic || $0.properties.numericType != nil }) }
        return moved(shown, of: typed).allSatisfy {
            NSIntersectionRange($0, span).length == 0 && !touching($0, span) && letters(a.substring(with: $0)) == letters(b.substring(with: $0))
                && plainMove(a.substring(with: $0), b.substring(with: $0))
        }
    }

    /// Whether a moved run changes nothing protected: it holds no backtick, mention sign or slash, or it is
    /// a name with its "@" moved from one end to the other, as display order lays a mention out.
    static func plainMove(_ shown: String, _ typed: String) -> Bool {
        // Paragraph boundaries do not move with bidi runs; these readings need the copy proof.
        guard !shown.contains(where: \.isNewline), !typed.contains(where: \.isNewline) else { return false }
        let delimiters: Set<Character> = ["`", "@", "/"]
        guard shown.contains(where: delimiters.contains) || typed.contains(where: delimiters.contains) else { return true }
        func flipped(_ a: String, _ b: String) -> Bool {
            a.hasPrefix("@") && b == a.dropFirst() + "@" && !a.dropFirst().contains(where: delimiters.contains)
        }
        return flipped(typed, shown) || flipped(shown, typed)
    }

    /// Whether a reading after a paste confirms it turned `draft` into `next`, the paste at `pasted`:
    /// exactly, or in display order away from the paste, or, when no other span of the draft holds the
    /// word's characters (`distinct`), anywhere in display order as long as the fix changed which characters
    /// the text holds. A paste that went elsewhere, or nowhere, leaves other characters.
    public static func confirms(_ reading: String, next: String, draft: String, pasted: NSRange,
                                distinct: @autoclosure () -> Bool) -> Bool {
        if sameDraft(reading, next) || reordered(reading, of: next, awayFrom: pasted) { return true }
        return reordered(reading, of: next) && !sameCharacters(next, draft) && distinct()
    }

    /// Which of `candidates` the editor's `reading` is: one it equals, else, where readings come in display
    /// order (`ordered`), the only one it is a reordering of. Nil when it is none, or ambiguous (a fix that
    /// only moves letters leaves the draft before and after it with the same characters).
    public static func base(of reading: String, among candidates: [String], ordered: Bool) -> String? {
        if let exact = candidates.first(where: { sameDraft(reading, $0) }) { return exact }
        guard ordered else { return nil }
        let moved = candidates.filter { reordered(reading, of: $0) }
        return moved.count == 1 ? moved[0] : nil
    }

    /// Whether each word's characters, in any order, occur in exactly one span of `text`: the word itself.
    /// A paste over any other span of that length would leave other characters, so a reading in display
    /// order can't hide where it went.
    public static func distinct(_ words: [String], in text: String) -> Bool {
        let all = units(text)
        return words.allSatisfy { word in
            let target = units(word), length = target.count
            guard length > 0, length <= all.count else { return false }
            // A window sliding over the text, with how many units it holds of each kind against the word's.
            var surplus: [UInt16: Int] = [:]
            for unit in target { surplus[unit, default: 0] -= 1 }
            var off = 0
            func add(_ unit: UInt16, _ delta: Int) {
                let was = surplus[unit, default: 0], now = was + delta
                off += (now == 0 ? 0 : 1) - (was == 0 ? 0 : 1)
                surplus[unit] = now
            }
            off = surplus.values.filter { $0 != 0 }.count
            var matches = 0
            for index in all.indices {
                add(all[index], 1)
                if index >= length { add(all[index - length], -1) }
                if index >= length - 1, off == 0 {
                    matches += 1
                    if matches > 1 { return false }
                }
            }
            return matches == 1
        }
    }

    /// Whether `copied`, a copy of the editor's text in the order typed, is `text`: the same characters in
    /// the same order, with each gap keeping at least its known line breaks (copies can add block separators
    /// Accessibility omits), and each image or chip (U+FFFC) as nothing or a short alt text. Where words start
    /// and end still counts: moved backticks, mention signs or spaces show.
    public static func copied(_ copied: String, matches text: String) -> Bool {
        // What makes text protected must read the same: code can't cross a line break, so a moved one shows.
        func protected(_ text: String) -> [String] {
            CorrectionPolicy.protectedSpans(text).filter { $0 != "\u{FFFC}" }
                .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        }
        guard protected(copied) == protected(text) else { return false }
        // Spaces collapse, but known blank lines must not disappear. CRLF is one Character and one break.
        func words(_ text: String) -> [UInt16] {
            var out: [UInt16] = [], pending: [UInt16] = []
            for character in text {
                if character.isWhitespace {
                    if character.isNewline {
                        if pending == [0x20] { pending.removeAll(keepingCapacity: true) }
                        pending.append(0x0A)
                    } else if pending.isEmpty { pending.append(0x20) }
                } else {
                    if !out.isEmpty { out.append(contentsOf: pending) }
                    pending.removeAll(keepingCapacity: true)
                    out.append(contentsOf: character.utf16)
                }
            }
            return out
        }
        let space: UInt16 = 0x20, all = words(copied)
        let pieces = words(text).split(separator: 0xFFFC, omittingEmptySubsequences: false).map(Array.init)
        // Matching is bounded by the placeholders; a draft with this many chips isn't checked by copy.
        guard pieces.count <= 65 else { return false }
        func trimmed(_ piece: [UInt16]) -> [UInt16] { Array(piece.drop { $0 == space }.reversed().drop { $0 == space }.reversed()) }
        func end(of piece: [UInt16], at start: Int) -> Int? {
            var index = 0, at = start
            while index < piece.count {
                guard at < all.count else { return nil }
                if piece[index] == 0x0A {
                    let first = index, copied = at
                    while index < piece.count, piece[index] == 0x0A { index += 1 }
                    while at < all.count, all[at] == 0x0A { at += 1 }
                    guard at - copied >= index - first else { return nil }
                } else {
                    guard piece[index] == all[at] else { return nil }
                    index += 1; at += 1
                }
            }
            return at
        }
        guard pieces.count > 1 else { return end(of: pieces[0], at: 0) == all.count }
        // Where each piece can end in the copy, piece by piece: a set of positions, so it stays bounded.
        var ends: Set<Int> = end(of: trimmed(pieces[0]), at: 0).map { [$0] } ?? []
        for index in 1..<pieces.count {
            let piece = trimmed(pieces[index]), before = pieces[index - 1], current = pieces[index]
            let spaced = before.last == space || current.first == space
            let edge = piece.isEmpty && index == pieces.count - 1 || index == 1 && trimmed(pieces[0]).isEmpty
            var next: Set<Int> = []
            for start in ends {
                // A short alt text or nothing, with a space where the draft had one beside the placeholder.
                for lead in spaced || edge ? [0, 1] : [0] where lead == 0 || start < all.count && all[start] == space {
                    var alt = start + lead
                    while true {
                        for trail in spaced || edge ? [0, 1] : [0] {
                            let at = alt + trail
                            guard trail == 0 || alt < all.count && all[alt] == space else { continue }
                            // Spaced: at least one space, here or just before (placeholders that copy as nothing
                            // share theirs), unless at the very edge of the text.
                            if spaced, !edge, lead + trail == 0, !(start > 0 && all[start - 1] == space) { continue }
                            if let end = end(of: piece, at: at) { next.insert(end) }
                        }
                        // Alt text may hold spaces ("team photo"), never a line break.
                        guard alt < all.count, alt - start - lead < 32, all[alt] != 0x0A else { break }
                        alt += 1
                    }
                }
            }
            ends = next
        }
        return ends.contains(all.count)
    }

    /// Whether nothing outside `range` of `text` could make text in it protected if it moved in: no
    /// backtick (code), mention sign or slash (a path or link) outside it.
    public static func inert(outside range: NSRange, of text: String) -> Bool {
        let source = text as NSString
        guard NSMaxRange(range) <= source.length else { return false }
        let outside = source.substring(to: range.location) + source.substring(from: NSMaxRange(range))
        return !outside.contains { "`@/".contains($0) }
    }

    /// The smallest runs that hold the moved characters: each starts where the two texts first differ
    /// and ends once both sides hold the same characters again. Empty when they aren't the same
    /// characters.
    static func moved(_ shown: String, of typed: String) -> [NSRange] {
        let a = units(shown), b = units(typed)
        guard a.count == b.count else { return [] }
        var runs: [NSRange] = [], balance: [UInt16: Int] = [:], start: Int?
        for index in a.indices {
            if start == nil {
                guard a[index] != b[index] else { continue }
                start = index
            }
            balance[a[index], default: 0] += 1
            balance[b[index], default: 0] -= 1
            if balance.values.allSatisfy({ $0 == 0 }), let first = start {
                runs.append(NSRange(location: first, length: index - first + 1))
                balance = [:]; start = nil
            }
        }
        return start == nil ? runs : []
    }

    /// A run that ends where the span starts, or starts where it ends: a word beside a moved run may
    /// have lost or gained a neighbour.
    private static func touching(_ run: NSRange, _ span: NSRange) -> Bool {
        NSMaxRange(run) == span.location || NSMaxRange(span) == run.location
    }

    private static func sameCharacters(_ a: String, _ b: String) -> Bool { units(a).sorted() == units(b).sorted() }

    /// UTF-16 units, a non-breaking space as a space, as `sameDraft` reads them.
    private static func units(_ text: String) -> [UInt16] { text.utf16.map { $0 == 0xA0 ? 0x20 : $0 } }

    private static func rightToLeft(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x0590...0x08FF).contains($0.value) || (0xFB1D...0xFDFF).contains($0.value) || (0xFE70...0xFEFE).contains($0.value) }
    }
}
