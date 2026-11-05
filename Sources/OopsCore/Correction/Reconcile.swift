import Foundation

/// One change between a source and a correction of it, at its UTF-16 offset in the source.
public struct TextChange: Codable, Equatable, Sendable {
    /// The check a refused change failed.
    public enum Rule: String, Codable, Sendable { case lineBreaks, edges, protectedSpan, embeddedObject }
    public var location: Int
    public var original: String
    public var replacement: String
    public var rule: Rule?
    public var range: NSRange { NSRange(location: location, length: original.utf16.count) }

    public init(location: Int, original: String, replacement: String, rule: Rule? = nil) {
        self.location = location; self.original = original; self.replacement = replacement; self.rule = rule
    }
}

/// A model's answer cut down to what is safe to apply. Each change that alters line breaks, edge
/// whitespace or a protected span, or adds an embedded object, is dropped on its own, so a partly
/// bad answer still fixes the rest. Changes that only swap typography (quotes, dashes, ellipses,
/// non-breaking spaces, line endings, Unicode forms) are absorbed: the source's characters stay.
public struct Reconciliation: Equatable, Sendable {
    /// The source with every kept change applied.
    public let text: String
    public let dropped: [TextChange]
    /// Changes that were only typographic drift.
    public let absorbed: Int
}

extension TextChange.Rule {
    var error: CorrectionError {
        switch self {
        case .lineBreaks, .edges: .message("The correction changed line breaks or edge whitespace. Nothing replaced.")
        case .protectedSpan: .message("The correction changed code, a link, a mention or a path. Nothing replaced.")
        case .embeddedObject: .message("This text contains an embedded object. Select a plain text span instead.")
        }
    }
}

public extension CorrectionPolicy {
    /// Decodes the model's answer and keeps its safe changes. `prefix` and `suffix` are the draft
    /// around a selection: protected spans are checked in the whole draft, so a selection can't
    /// rewrite part of a mention, URL or code span. Throws when the answer is malformed, or when it
    /// changed something and none of it was safe.
    static func reconcile(_ raw: String, original: String, prefix: String = "", suffix: String = "") throws -> Reconciliation {
        let answer = try restoredAnswer(raw, original: original)
        guard !isRewrite(answer, of: original) else {
            throw CorrectionError.message("The model rewrote or answered the text instead of correcting it. Nothing replaced.")
        }
        let result = reconcile(answer: answer, original: original, prefix: prefix, suffix: suffix)
        if sameText(result.text, original), let rule = result.dropped.first?.rule { throw rule.error }
        try validate(result.text, original: original)
        return result
    }

    internal static func reconcile(answer: String, original: String, prefix: String = "", suffix: String = "") -> Reconciliation {
        let answer = absorbingDrift(answer, original: original)
        let source = original as NSString, target = answer as NSString
        let breaks = breaks(original), edges = edges(original), spans = protectedSpans(prefix + original + suffix)
        // Tokens that differ only in typography match outright; longer drift ("--" for "—") is
        // caught hunk by hunk.
        let diff = WordDiff(before: original, after: answer, key: fold)
        var kept: [TextChange] = [], dropped: [TextChange] = [], absorbed = diff.equivalent
        for hunk in diff.hunks {
            var change = TextChange(location: hunk.before.location, original: source.substring(with: hunk.before),
                                    replacement: target.substring(with: hunk.after))
            if sameText(fold(change.original), fold(change.replacement)) { absorbed += 1; continue }
            // Checked with the changes kept so far: two changes can be safe apart and not together.
            let candidate = applying(kept + [change], to: original)
            change.rule = if self.breaks(candidate) != breaks { .lineBreaks }
                else if self.edges(candidate) != edges { .edges }
                else if change.replacement.contains("\u{0000}") || attachments(change.replacement) > attachments(change.original) { .embeddedObject }
                else if !Self.same(protectedSpans(prefix + candidate + suffix), spans) { .protectedSpan }
                else { nil }
            if change.rule == nil { kept.append(change) } else { dropped.append(change) }
        }
        return Reconciliation(text: applying(kept, to: original), dropped: dropped, absorbed: absorbed)
    }

    /// Whether the answer is a reply, a translation or a rewrite rather than a correction: much
    /// longer than the draft, or (past a few words) more than 40% of its characters edited, case
    /// and typography aside. Typo fixes stay close to the draft; the "safe" pieces of a rewrite
    /// would be nonsense.
    internal static func isRewrite(_ answer: String, of original: String) -> Bool {
        let length = original.count
        if answer.count > length * 2 + 40 { return true }
        guard length >= 20 else { return false }
        let source = original as NSString, target = answer as NSString
        var edits = 0
        for hunk in WordDiff(before: original, after: answer, key: fold).hunks {
            edits += distance(fold(source.substring(with: hunk.before)).lowercased(), fold(target.substring(with: hunk.after)).lowercased())
        }
        return Double(edits) > Double(length) * 0.4
    }

    /// Levenshtein distance in characters. Past 2,000 characters a side (a long draft's diff can come
    /// back as one hunk), the characters of the words the two sides don't share, which counts a typo
    /// as its word and a rewrite as nearly everything.
    internal static func distance(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if x.count > 2_000 || y.count > 2_000 { return unsharedWords(a, b) }
        guard !x.isEmpty, !y.isEmpty else { return max(x.count, y.count) }
        var previous = Array(0...y.count), current = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            current[0] = i
            for j in 1...y.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            swap(&previous, &current)
        }
        return previous[y.count]
    }

    private static func unsharedWords(_ a: String, _ b: String) -> Int {
        func words(_ text: String) -> [String: Int] {
            matches(#"[\p{L}\p{N}]+"#, text).reduce(into: [:]) { $0[$1, default: 0] += 1 }
        }
        let left = words(a), right = words(b)
        func unshared(_ one: [String: Int], _ other: [String: Int]) -> Int {
            one.reduce(0) { $0 + max(0, $1.value - (other[$1.key] ?? 0)) * $1.key.count }
        }
        return max(unshared(left, right), unshared(right, left))
    }

    private static func attachments(_ text: String) -> Int { text.unicodeScalars.count { $0 == "\u{FFFC}" } }

    /// `changes` in source order, applied last to first so earlier offsets hold.
    internal static func applying(_ changes: [TextChange], to text: String) -> String {
        let result = NSMutableString(string: text)
        for change in changes.reversed() { result.replaceCharacters(in: change.range, with: change.replacement) }
        return result as String
    }

    /// Typography the source never uses is mapped back to what it does: curly quotes to straight
    /// ones, non-breaking spaces to spaces, and the answer into the source's Unicode form.
    internal static func absorbingDrift(_ answer: String, original: String) -> String {
        var text = answer
        if sameText(original, original.precomposedStringWithCanonicalMapping) { text = text.precomposedStringWithCanonicalMapping }
        else if sameText(original, original.decomposedStringWithCanonicalMapping) { text = text.decomposedStringWithCanonicalMapping }
        for (curly, plain) in [("‘’", "'"), ("“”", "\""), ("\u{00A0}\u{202F}\u{2007}", " ")]
        where !original.unicodeScalars.contains(where: { curly.unicodeScalars.contains($0) }) {
            text = String(String.UnicodeScalarView(text.unicodeScalars.map { curly.unicodeScalars.contains($0) ? plain.unicodeScalars.first! : $0 }))
        }
        return text
    }

    /// What a change looks like with typography set aside: equal folds mean the change was drift.
    internal static func fold(_ text: String) -> String {
        var folded = ""
        for scalar in text.replacingOccurrences(of: "\r\n", with: "\n").precomposedStringWithCanonicalMapping.unicodeScalars {
            switch scalar {
            case "‘", "’", "‚", "′": folded += "'"
            case "“", "”", "„", "″": folded += "\""
            case "–", "—", "‒", "―", "−": folded += "-"
            case "…": folded += "..."
            case "\u{00A0}", "\u{202F}", "\u{2007}": folded += " "
            case "\r": folded += "\n"
            default: folded.unicodeScalars.append(scalar)
            }
        }
        // "--" typed for a dash.
        while folded.contains("--") { folded = folded.replacingOccurrences(of: "--", with: "-") }
        return folded
    }

    internal static func same(_ a: [String], _ b: [String]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { sameText($0, $1) }
    }
}
