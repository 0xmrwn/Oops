import Foundation

// The spacing of text written at the caret, ported from Hex (github.com/anomalyco/hex, `src/paste.rs` at
// 1b82cc0; MIT, Copyright (c) 2026 Christopher Langton): `join`, `needs_leading_space` (Labs › Smart spacing),
// `ends_sentence`, `is_opening`, `is_closing`, `set_initial_case` and `sentence_initial_word`.

/// How dictated text meets what the field already holds. Hex reads only the character before the caret; a
/// dictation that follows the previous one directly is joined to it, sentence case included.
public enum InsertSpacing {
    /// The text to paste over `selection` in `value`. `previous` is the last text this insert path wrote:
    /// when the field's text before the caret ends with it, the two are one dictation going on (Hex's
    /// continuation) and are joined. Otherwise one leading space goes in where the character before the
    /// caret asks for it. A selection, a field that can't be read, the start of a field and a field showing
    /// only its placeholder leave the text as it is.
    public static func shaped(_ text: String, in value: String?, selection: NSRange?, previous: String? = nil,
                              placeholders: [String] = []) -> String {
        guard let value, let selection, selection.length == 0, selection.location > 0,
              selection.location <= value.utf16.count, !CorrectionPolicy.isPlaceholder(value, hints: placeholders),
              let head = String(value.utf16.prefix(selection.location)) else { return text }
        if let previous, !previous.isEmpty, head.hasSuffix(previous) { return join(previous, text) }
        guard let before = head.last, needsLeadingSpace(before, text) else { return text }
        return " " + text
    }

    /// `next` written right after `previous`, from the same dictation: a space between them unless one is
    /// there or punctuation closes up to it, and the first word's case set by whether `previous` ended a sentence.
    public static func join(_ previous: String, _ next: String) -> String {
        var next = setInitialCase(next, uppercase: endsSentence(previous))
        let needsSpace = previous.last.map { !$0.isWhitespace && !isOpening($0) } == true
            && next.first.map { !$0.isWhitespace && !isClosing($0) } == true
        if needsSpace { next.insert(" ", at: next.startIndex) }
        return next
    }

    /// Whether `text` pasted right after `previous` needs a space between: after a letter, digit, sentence
    /// punctuation, or closing bracket or quote, never after whitespace, opening punctuation, or symbols such
    /// as `@` and `$`, and never before text that starts with whitespace or closing punctuation.
    public static func needsLeadingSpace(_ previous: Character, _ text: String) -> Bool {
        guard let first = text.first, !first.isWhitespace, !isClosing(first) else { return false }
        return previous.isLetter || previous.isNumber || ".,;:!?…)]}”’»".contains(previous)
    }

    static func endsSentence(_ text: String) -> Bool {
        var trimmed = Substring(text)
        while let last = trimmed.last, last.isWhitespace { trimmed = trimmed.dropLast() }
        while let last = trimmed.last, "'\")]}".contains(last) { trimmed = trimmed.dropLast() }
        return trimmed.last.map { ".?!".contains($0) } == true
    }

    static func isOpening(_ character: Character) -> Bool { "([{".contains(character) }

    static func isClosing(_ character: Character) -> Bool { ",.?!;:)]}".contains(character) }

    /// Capitalizes the first letter after a sentence's end; mid-sentence, lowers it only on a word that
    /// starts sentences (`And`, `The`…), so likely proper nouns (`GitHub`) keep theirs.
    static func setInitialCase(_ text: String, uppercase: Bool) -> String {
        guard let index = text.firstIndex(where: \.isLetter) else { return text }
        let character = text[index]
        if uppercase, character.isLowercase {
            return text.replacingCharacters(in: index ... index, with: character.uppercased())
        }
        if !uppercase, character.isUppercase, sentenceInitialWord(text[index...]) {
            return text.replacingCharacters(in: index ... index, with: character.lowercased())
        }
        return text
    }

    static func sentenceInitialWord(_ text: Substring) -> Bool {
        let word = text.prefix { $0.isLetter || $0 == "'" }.lowercased()
        return ["a", "an", "and", "as", "because", "but", "for", "if", "nor", "or", "so", "the", "then", "though", "to",
                "when", "while", "yet"].contains(word)
    }
}
