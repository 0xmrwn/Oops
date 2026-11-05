import Foundation

/// The pastes that turn one draft into another: one per changed word, so the text between fixes
/// (mentions, attachments, code, formatted words) is never pasted over. Each span is trimmed to the
/// characters that differ, then widened back to the whole words they sit in: a paste always
/// replaces some text, which the editor's selection can be checked against before pasting, and
/// never lands at a bare caret, which editors may not move. Changes are in `before`'s UTF-16
/// offsets, in order, never overlapping; apply them last to first so each offset still holds. A
/// change outside any word keeps the character before it (after it, at the start), since pasting
/// nothing deletes nothing. Past `limit`, the closest spans join across plain gaps, never across a
/// line break or anything protected.
public enum TextEdits {
    /// A span in both drafts, so trimming, widening and joining keep the two sides in step.
    private struct Span { var before: NSRange; var after: NSRange }

    public static func between(_ before: String, _ after: String, limit: Int = 24) -> [TextChange] {
        let source = before as NSString, target = after as NSString
        var spans: [Span] = []
        for hunk in WordDiff(before: before, after: after).hunks {
            guard let span = trimmed(Span(before: hunk.before, after: hunk.after), source, target) else { continue }
            let widened = pastable(wholeWords(span, source, target), source, target)
            // Widening can reach the neighbouring span: the two become one.
            if let last = spans.last, NSMaxRange(last.before) >= widened.before.location {
                spans[spans.count - 1] = Span(before: NSUnionRange(last.before, widened.before), after: NSUnionRange(last.after, widened.after))
            } else {
                spans.append(widened)
            }
        }
        while spans.count > limit {
            let gaps = spans.indices.dropLast().compactMap { i -> (index: Int, length: Int)? in
                let gap = NSRange(location: NSMaxRange(spans[i].before), length: spans[i + 1].before.location - NSMaxRange(spans[i].before))
                return joinable(source.substring(with: gap)) ? (i, gap.length) : nil
            }
            guard let closest = gaps.min(by: { $0.length < $1.length }) else { break }
            let first = spans[closest.index], second = spans[closest.index + 1]
            spans[closest.index] = Span(before: NSUnionRange(first.before, second.before), after: NSUnionRange(first.after, second.after))
            spans.remove(at: closest.index + 1)
        }
        return spans.map {
            TextChange(location: $0.before.location, original: source.substring(with: $0.before), replacement: target.substring(with: $0.after))
        }
    }

    /// An internal replacement that keeps unchanged graphemes at both word boundaries. Empty
    /// selections cannot be copied to prove them, so insertions and deletions keep the whole word.
    public static func interior(of edit: TextChange) -> TextChange? {
        let source = edit.original as NSString, target = edit.replacement as NSString
        guard let span = trimmed(Span(before: NSRange(location: 0, length: source.length),
                                      after: NSRange(location: 0, length: target.length)), source, target),
              span.before.location > 0, NSMaxRange(span.before) < source.length,
              span.after.location > 0, NSMaxRange(span.after) < target.length,
              span.before.length > 0, span.after.length > 0 else { return nil }
        let (location, overflow) = edit.location.addingReportingOverflow(span.before.location)
        guard !overflow, TextOffsets.plausible(location: location, length: span.before.length) != nil else { return nil }
        return TextChange(location: location, original: source.substring(with: span.before),
                          replacement: target.substring(with: span.after), rule: edit.rule)
    }

    /// The span without the characters its two sides share at either end.
    private static func trimmed(_ span: Span, _ source: NSString, _ target: NSString) -> Span? {
        let a = Array(source.substring(with: span.before)), b = Array(target.substring(with: span.after))
        var start = 0
        while start < min(a.count, b.count), sameText(String(a[start]), String(b[start])) { start += 1 }
        var endA = a.count, endB = b.count
        while endA > start, endB > start, sameText(String(a[endA - 1]), String(b[endB - 1])) { endA -= 1; endB -= 1 }
        guard start < endA || start < endB else { return nil }
        let lead = String(a[..<start]).utf16.count
        return Span(before: NSRange(location: span.before.location + lead, length: String(a[start..<endA]).utf16.count),
                    after: NSRange(location: span.after.location + lead, length: String(b[start..<endB]).utf16.count))
    }

    /// The span grown over the unchanged word characters on either side (letters, marks and digits),
    /// up to `reach` UTF-16 units each way, so an unspaced script doesn't grow it into a sentence.
    private static func wholeWords(_ span: Span, _ source: NSString, _ target: NSString, reach: Int = 24) -> Span {
        var span = span
        func word(_ text: NSString, _ range: NSRange) -> String? {
            let value = text.substring(with: range)
            return value.unicodeScalars.allSatisfy(CharacterSet.alphanumerics.contains) ? value : nil
        }
        var grown = 0
        while grown < reach, span.before.location > 0, span.after.location > 0 {
            let a = source.rangeOfComposedCharacterSequence(at: span.before.location - 1)
            let b = target.rangeOfComposedCharacterSequence(at: span.after.location - 1)
            guard let left = word(source, a), let right = word(target, b), sameText(left, right) else { break }
            span = Span(before: NSUnionRange(a, span.before), after: NSUnionRange(b, span.after))
            grown += a.length
        }
        grown = 0
        while grown < reach, NSMaxRange(span.before) < source.length, NSMaxRange(span.after) < target.length {
            let a = source.rangeOfComposedCharacterSequence(at: NSMaxRange(span.before))
            let b = target.rangeOfComposedCharacterSequence(at: NSMaxRange(span.after))
            guard let left = word(source, a), let right = word(target, b), sameText(left, right) else { break }
            span = Span(before: NSUnionRange(span.before, a), after: NSUnionRange(span.after, b))
            grown += a.length
        }
        return span
    }

    /// A deletion or insertion outside any word, widened by one whole character of unchanged
    /// context: the one before it, unless that is an attachment or a line break and the one after
    /// isn't.
    private static func pastable(_ span: Span, _ source: NSString, _ target: NSString) -> Span {
        guard span.after.length == 0 || span.before.length == 0, source.length > span.before.length else { return span }
        let left = span.before.location > 0 && span.after.location > 0
            ? source.rangeOfComposedCharacterSequence(at: span.before.location - 1) : nil
        let right = NSMaxRange(span.before) < source.length ? source.rangeOfComposedCharacterSequence(at: NSMaxRange(span.before)) : nil
        func atom(_ range: NSRange?) -> Bool { range.map { source.substring(with: $0).contains { $0 == "\u{FFFC}" || $0.isNewline } } ?? true }
        if let left, !atom(left) || atom(right) {
            return Span(before: NSUnionRange(left, span.before),
                        after: NSRange(location: span.after.location - left.length, length: span.after.length + left.length))
        }
        guard let right else { return span }
        return Span(before: NSUnionRange(span.before, right), after: NSRange(location: span.after.location, length: span.after.length + right.length))
    }

    /// Whether `current` is `draft` with `pasted` put in somewhere, over some span or none: the
    /// editor took the paste, at a selection of its own rather than the one Oops made.
    public static func misplaced(_ pasted: String, in current: String, over draft: String) -> Bool {
        let c = Array(current.utf16), d = Array(draft.utf16), p = Array(pasted.utf16)
        // Prefix/suffix bounds eliminate impossible positions before searching. Comparing each
        // repeated letter's whole prefix would otherwise stall the input guard on long drafts.
        guard !p.isEmpty, c.count >= p.count, c != d, c.count - p.count <= d.count else { return false }
        let prefix = zip(c, d).prefix { $0 == $1 }.count
        let suffix = zip(c.reversed(), d.reversed()).prefix { $0 == $1 }.count
        let lower = max(0, c.count - p.count - suffix), upper = min(prefix, c.count - p.count)
        guard lower <= upper else { return false }
        let range = NSRange(location: lower, length: upper - lower + p.count)
        return (current as NSString).range(of: pasted, options: .literal, range: range).location != NSNotFound
    }

    /// How a field's value spells the atoms its text markers count as one U+FFFC each: nil when the
    /// value isn't that same text around them, else the units the value spends on them (0 when it
    /// leaves them out, as WebKit and Gecko do; more when it spells them as their alt text, as
    /// Chromium does).
    public static func atomSpelling(value: String, markers: String) -> Int? {
        let parts = markers.components(separatedBy: "\u{FFFC}").map { Array($0.utf16) }
        let text = Array(value.utf16)
        // Some text besides atoms: a text control is a single atom in its document's markers.
        guard parts.count > 1, parts.contains(where: { !$0.isEmpty }), text.starts(with: parts[0]) else { return nil }
        // The text after each run of atoms, with how many atoms the run holds: adjacent atoms share one gap.
        var runs: [(text: [UInt16], atoms: Int)] = [], atoms = 0
        for (index, part) in parts.enumerated().dropFirst() {
            atoms += 1
            if !part.isEmpty || index == parts.count - 1 { runs.append((part, atoms)); atoms = 0 }
        }
        var at = parts[0].count, spent = 0
        for (index, run) in runs.enumerated() {
            // An atom spelled out takes a few units at most (an emoji, a name).
            let most = 16 * run.atoms
            let gap: Int?
            if index == runs.count - 1 {
                // The last run ends the value: its atoms take whatever precedes the closing text.
                let rest = text.count - at - run.text.count
                gap = (0...most).contains(rest) && text.reversed().starts(with: run.text.reversed()) ? rest : nil
            } else {
                gap = (0...most).first { at + $0 + run.text.count <= text.count && Array(text[(at + $0)..<(at + $0 + run.text.count)]) == run.text }
            }
            guard let gap else { return nil }
            at += gap + run.text.count; spent += gap
        }
        return at == text.count ? spent : nil
    }

    /// Whether `current` is `expected` with the paste at `pasted` in place but other text changed beside
    /// it: an editor that normalises its content on paste (dropping a space next to an atom, say).
    public static func changedBeside(_ pasted: NSRange, current: String, expected: String) -> Bool {
        guard !sameText(current, expected) else { return false }
        return between(expected, current).allSatisfy { NSIntersectionRange($0.range, pasted).length == 0 }
    }

    /// `after` rebuilt on `current`: the draft as the editor reports it again, the same length as
    /// `before` and different only away from every change (a mention reordered in right-to-left text).
    /// Nil when a change's text isn't where it was.
    public static func rebase(before: String, after: String, onto current: String) -> String? {
        guard before.utf16.count == current.utf16.count else { return nil }
        let text = current as NSString, edits = between(before, after)
        guard edits.allSatisfy({ NSMaxRange($0.range) <= text.length && sameText(text.substring(with: $0.range), $0.original) })
        else { return nil }
        return CorrectionPolicy.applying(edits, to: current)
    }

    /// What an undo of a misplaced paste has done so far: brought back exactly the text before the
    /// paste, nothing yet, or gone further back (taking the person's own edits with it) or elsewhere.
    public enum Undo: Equatable, Sendable { case restored, pending, overshot }

    public static func undo(_ current: String, before draft: String, misplaced: String) -> Undo {
        if sameText(current, draft) { return .restored }
        return sameText(current, misplaced) ? .pending : .overshot
    }

    static func joinable(_ gap: String) -> Bool {
        !gap.contains(where: \.isNewline) && !gap.contains("`") && !gap.contains("@") && !gap.contains("\u{FFFC}")
            && CorrectionPolicy.protectedSpans(gap).isEmpty
    }
}
