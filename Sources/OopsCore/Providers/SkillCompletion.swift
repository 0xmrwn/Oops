import Foundation

/// A `/` or `$` and the letters after it, with the caret right behind them: what the person is typing as a skill's name.
public struct SkillCompletion: Equatable, Sendable {
    /// The sigil and what follows it, in UTF-16 units of the text.
    public let range: NSRange
    public let sigil: Character, partial: String

    /// Whether the one name offered is what has been typed, in any case: nothing is left to complete.
    public func isTyped(in matches: [String]) -> Bool {
        matches.count == 1 && matches[0].caseInsensitiveCompare(partial) == .orderedSame
    }

    /// What picking `name` writes over the range: the sigil the person typed, the name and a space.
    public func replacement(for name: String) -> String { "\(sigil)\(name) " }
}

public extension ClaudeSkills {
    /// The skill name being typed at `caret` (a UTF-16 offset), if there is one: a sigil at the start of a word, as
    /// `mentions` reads it, and name characters up to the caret and no further.
    static func completion(in text: String, caret: Int) -> SkillCompletion? {
        let string = text as NSString
        guard caret >= 0, caret <= string.length else { return nil }
        var start = caret
        while start > 0, isNameUnit(string.character(at: start - 1)) { start -= 1 }
        guard start > 0, let sigil = Unicode.Scalar(string.character(at: start - 1)), sigil == "/" || sigil == "$" else { return nil }
        if caret < string.length, isNameUnit(string.character(at: caret)) { return nil }
        let partial = string.substring(with: NSRange(location: start, length: caret - start))
        if let first = partial.first, !isAlphanumeric(first) { return nil }
        if start > 1 {
            let before = string.character(at: start - 2)
            guard let scalar = Unicode.Scalar(before),
                  Character(scalar).isWhitespace || "(\"'“‘".unicodeScalars.contains(scalar) else { return nil }
        }
        return SkillCompletion(range: NSRange(location: start - 1, length: caret - start + 1), sigil: Character(sigil), partial: partial)
    }

    /// The names to offer for what has been typed: those that start with it, then those that contain it, each in
    /// alphabetical order and ignoring case.
    static func suggestions(_ partial: String, from names: [String], limit: Int = 8) -> [String] {
        let typed = partial.lowercased()
        func sorted(_ names: [String]) -> [String] {
            names.sorted { ($0.lowercased(), $0) < ($1.lowercased(), $1) }
        }
        // Just the sigil so far: every name, in order.
        guard !typed.isEmpty else { return Array(sorted(names).prefix(limit)) }
        let matches = names.filter { $0.lowercased().contains(typed) }
        let prefixed = matches.filter { $0.lowercased().hasPrefix(typed) }
        let inside = matches.filter { !$0.lowercased().hasPrefix(typed) }
        return Array((sorted(prefixed) + sorted(inside)).prefix(limit))
    }

    /// Where the text names one of `known`, in UTF-16 units: the mentions the editor draws as tokens.
    static func tokenRanges(in text: String, known: [String]) -> [NSRange] {
        let names = Set(known.map { $0.lowercased() })
        return mentions(in: text).filter { names.contains($0.name.lowercased()) }.map { NSRange($0.range, in: text) }
    }

    private static func isNameUnit(_ unit: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(unit), scalar.isASCII else { return false }
        return isAlphanumeric(Character(scalar)) || scalar == "_" || scalar == "-"
    }
}
