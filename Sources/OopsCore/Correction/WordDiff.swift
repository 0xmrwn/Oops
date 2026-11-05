import Foundation

/// Word-level diff between two drafts: LCS over word, whitespace and
/// punctuation tokens. `hunks` pair each changed UTF-16 range of `before` with
/// its replacement range in `after`; `afterRanges` are the same changes trimmed
/// of edge whitespace, for highlights. A pure deletion yields an empty range at
/// the deletion point. With `key`, tokens whose keys are equal match even when
/// their text differs; `equivalent` counts those matches.
public struct WordDiff: Sendable {
    public struct Hunk: Equatable, Sendable {
        public let before: NSRange
        public let after: NSRange
    }

    public let hunks: [Hunk]
    public let afterRanges: [NSRange]
    public let equivalent: Int
    public var changes: Int { hunks.count }

    private struct Token { let text: String; let key: String; let range: NSRange; let isSpace: Bool }

    public init(before: String, after: String, key: ((String) -> String)? = nil) {
        let a = Self.tokenize(before, key: key), b = Self.tokenize(after, key: key)
        var equivalent = 0
        func match(_ x: Token, _ y: Token) -> Bool {
            guard x.key == y.key else { return false }
            if x.text != y.text { equivalent += 1 }
            return true
        }
        var prefix = 0
        while prefix < min(a.count, b.count), match(a[prefix], b[prefix]) { prefix += 1 }
        var suffix = 0
        while suffix < min(a.count, b.count) - prefix, match(a[a.count - 1 - suffix], b[b.count - 1 - suffix]) { suffix += 1 }
        let midA = Array(a[prefix..<(a.count - suffix)]), midB = Array(b[prefix..<(b.count - suffix)])

        // Token index ranges per hunk, in a and b.
        var spans: [(a: Range<Int>, b: Range<Int>)] = []
        if midA.isEmpty && midB.isEmpty {
            spans = []
        } else if midA.count * midB.count > 1_500_000 || midA.isEmpty || midB.isEmpty {
            spans = [(prefix..<(prefix + midA.count), prefix..<(prefix + midB.count))]
        } else {
            let n = midA.count, m = midB.count
            var table = [Int32](repeating: 0, count: (n + 1) * (m + 1))
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    table[i * (m + 1) + j] = midA[i].key == midB[j].key
                        ? table[(i + 1) * (m + 1) + j + 1] + 1
                        : max(table[(i + 1) * (m + 1) + j], table[i * (m + 1) + j + 1])
                }
            }
            var i = 0, j = 0, startA = 0, startB = 0, open = false
            func close() {
                if open { spans.append((prefix + startA..<prefix + i, prefix + startB..<prefix + j)) }
                open = false
            }
            while i < n || j < m {
                if i < n, j < m, match(midA[i], midB[j]) { close(); i += 1; j += 1; continue }
                if !open { open = true; startA = i; startB = j }
                if j < m, i == n || table[i * (m + 1) + j + 1] >= table[(i + 1) * (m + 1) + j] { j += 1 } else { i += 1 }
            }
            close()
        }
        func range(_ tokens: [Token], _ indices: Range<Int>, end: Int) -> NSRange {
            let start = indices.lowerBound < tokens.count ? tokens[indices.lowerBound].range.location : end
            guard !indices.isEmpty else { return NSRange(location: start, length: 0) }
            return NSRange(location: start, length: NSMaxRange(tokens[indices.upperBound - 1].range) - start)
        }
        self.equivalent = equivalent
        let endA = (before as NSString).length, endB = (after as NSString).length
        hunks = spans.map { Hunk(before: range(a, $0.a, end: endA), after: range(b, $0.b, end: endB)) }
        afterRanges = spans.map { span in
            // Trim whitespace at the edges so the highlight hugs the changed words.
            var lower = span.b.lowerBound, upper = span.b.upperBound
            while lower < upper, b[lower].isSpace { lower += 1 }
            while upper > lower, b[upper - 1].isSpace { upper -= 1 }
            if lower == upper { return NSRange(location: span.b.lowerBound < b.count ? b[span.b.lowerBound].range.location : endB, length: 0) }
            let start = b[lower].range.location
            return NSRange(location: start, length: NSMaxRange(b[upper - 1].range) - start)
        }
    }

    private static func tokenize(_ text: String, key: ((String) -> String)?) -> [Token] {
        enum Kind { case word, space, mark }
        func kind(_ c: Character) -> Kind {
            if c.isWhitespace { return .space }
            if c.isLetter || c.isNumber || c == "'" || c == "’" || c == "_" { return .word }
            return .mark
        }
        var tokens: [Token] = []
        var current = "", currentKind: Kind? = nil, start = 0, offset = 0
        func flush() {
            guard let currentKind, !current.isEmpty else { return }
            tokens.append(Token(text: current, key: key?(current) ?? current,
                                range: NSRange(location: start, length: offset - start), isSpace: currentKind == .space))
        }
        for c in text {
            let k = kind(c)
            if k != currentKind || k == .mark { flush(); current = ""; currentKind = k; start = offset }
            current.append(c); offset += c.utf16.count
        }
        flush()
        return tokens
    }
}
