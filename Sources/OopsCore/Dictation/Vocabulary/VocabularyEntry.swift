import Foundation

// The vocabulary's entry model and list rules, ported from Hex (github.com/anomalyco/hex, `src/dictation/vocabulary.rs`
// at 1b82cc0; MIT, Copyright (c) 2026 Christopher Langton). Hex's process-wide saved list, focused-mode terms,
// settings.json reading and CLI plumbing have no place here: this is the value and its rules, nothing saved.

/// A name the engine should know (a person, project or product) with the spellings a transcript may show instead
/// ("sounds like"). Decodes from a plain string or from `{"term": ..., "sounds_like": [...]}`, as Hex's settings do.
public struct VocabularyEntry: Codable, Sendable, Equatable {
    public var term: String
    public var soundsLike: [String]

    public init(term: String, soundsLike: [String] = []) {
        self.term = term
        self.soundsLike = soundsLike
    }

    private enum CodingKeys: String, CodingKey {
        case term
        case soundsLike = "sounds_like"
    }

    public init(from decoder: any Decoder) throws {
        if let plain = try? decoder.singleValueContainer().decode(String.self) {
            self.init(term: plain)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            term: try container.decode(String.self, forKey: .term),
            soundsLike: try container.decodeIfPresent([String].self, forKey: .soundsLike) ?? []
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(term, forKey: .term)
        if !soundsLike.isEmpty { try container.encode(soundsLike, forKey: .soundsLike) }
    }
}

public enum VocabularyError: Error, Equatable, Sendable, LocalizedError {
    case emptyTerm
    case tooLong(String)
    case tooManyTerms
    case tooManySoundsLike

    public var errorDescription: String? {
        switch self {
        case .emptyTerm: "a vocabulary term can't be empty"
        case let .tooLong(text): "“\(text)” is longer than \(Vocabulary.maxTermCharacters) characters"
        case .tooManyTerms: "the vocabulary holds at most \(Vocabulary.maxEntries) terms"
        case .tooManySoundsLike: "a term takes at most \(Vocabulary.maxSoundsLike) “sounds like” spellings"
        }
    }
}

public enum Vocabulary {
    /// Longest term or "sounds like" entry, in characters (Unicode scalars, as Hex counts them).
    public static let maxTermCharacters = 64
    /// Most entries in the list, and most "sounds like" spellings per entry.
    public static let maxEntries = 500
    public static let maxSoundsLike = 16

    /// Splits a comma-separated "sounds like" field into trimmed spellings.
    public static func parseSoundsLike(_ raw: String) -> [String] {
        raw.split(separator: ",", omittingEmptySubsequences: false).map { clean(String($0)) }.filter { !$0.isEmpty }
    }

    static func clean(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func same(_ left: String, _ right: String) -> Bool { left.lowercased() == right.lowercased() }

    private static func length(_ text: String) -> Int { text.unicodeScalars.count }

    /// Adds `term`, or adds new `soundsLike` spellings to an existing entry with the same term in any case.
    /// Returns whether the list changed.
    @discardableResult
    public static func add(_ list: inout [VocabularyEntry], term: String, soundsLike: [String] = []) throws -> Bool {
        let term = clean(term)
        if term.isEmpty { throw VocabularyError.emptyTerm }
        var spellings: [String] = []
        for spelling in soundsLike.map(clean) {
            if spelling.isEmpty || same(spelling, term) || spellings.contains(where: { same($0, spelling) }) { continue }
            spellings.append(spelling)
        }
        if let long = ([term] + spellings).first(where: { length($0) > maxTermCharacters }) {
            throw VocabularyError.tooLong(long)
        }
        let existing = list.firstIndex { same($0.term, term) }
        if existing == nil, list.count >= maxEntries { throw VocabularyError.tooManyTerms }
        var merged = existing.map { list[$0].soundsLike } ?? []
        let before = merged.count
        for spelling in spellings where !merged.contains(where: { same($0, spelling) }) { merged.append(spelling) }
        if merged.count > maxSoundsLike { throw VocabularyError.tooManySoundsLike }
        if let index = existing {
            list[index].soundsLike = merged
            return merged.count != before
        }
        list.append(VocabularyEntry(term: term, soundsLike: merged))
        return true
    }

    /// Like `add`, but keeps what fits instead of refusing: a long term is cut to its first 64 characters, and a
    /// long spelling or one past the 16th is left out. A full list still takes no new term. Returns whether
    /// anything was cut or left out.
    @discardableResult
    public static func addClamped(_ list: inout [VocabularyEntry], term: String, soundsLike: [String] = []) -> Bool {
        var term = clean(term)
        var clamped = false
        if length(term) > maxTermCharacters {
            term = clean(String(String.UnicodeScalarView(term.unicodeScalars.prefix(maxTermCharacters))))
            clamped = true
        }
        if term.isEmpty { return clamped }
        if (try? add(&list, term: term)) == nil { return true }
        for spelling in soundsLike where (try? add(&list, term: term, soundsLike: [spelling])) == nil { clamped = true }
        return clamped
    }

    /// Whether the list has an entry for `term`, in any case.
    public static func contains(_ list: [VocabularyEntry], term: String) -> Bool {
        let term = clean(term)
        return list.contains { same($0.term, term) }
    }

    /// Removes the entry for `term`, in any case. Returns whether it was there.
    @discardableResult
    public static func remove(_ list: inout [VocabularyEntry], term: String) -> Bool {
        let term = clean(term)
        let before = list.count
        list.removeAll { same($0.term, term) }
        return list.count != before
    }

    /// `first`, then the entries of `then` whose term `first` lacks, in any case.
    public static func merged(_ first: [VocabularyEntry], _ then: [VocabularyEntry]) -> [VocabularyEntry] {
        if first.isEmpty { return then }
        var list = first
        for entry in then where !contains(list, term: entry.term) { list.append(entry) }
        return list
    }

    /// Adds each name in recognition hints saved before they merged into the vocabulary (comma, semicolon or line
    /// separated), skipping names already listed in any case. Returns whether the list changed.
    @discardableResult
    public static func foldHints(_ list: inout [VocabularyEntry], _ hints: String) -> Bool {
        let before = list.count
        for hint in hints.split(whereSeparator: { ",;\n".contains($0) }) { addClamped(&list, term: String(hint)) }
        return list.count != before
    }
}
