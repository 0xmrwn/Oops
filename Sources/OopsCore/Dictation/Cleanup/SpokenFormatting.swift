import Foundation

// Spoken formatting, ported from Hex (github.com/anomalyco/hex, `src/dictation/spoken_formatting.rs` at v3.4.0; MIT,
// Copyright (c) 2026 Christopher Langton), with French added in the same style.

/// Whole spoken phrases ("new line", "line break", "new paragraph", "open quote", "close quote", and "quote" ...
/// "unquote" around words) become line breaks and quotation marks, in English, Spanish ("nuevo párrafo", "abre
/// comillas") and French ("à la ligne", "nouveau paragraphe", "ouvrez les guillemets"). Matching ignores case and
/// accents and needs word boundaries, so "newline" or "new liner" stay as they are. The commas, periods and spaces
/// a model puts around a command go with it.
public enum SpokenFormatting {
    private enum Command {
        case lineBreak(String)
        case openQuote
        case closeQuote
    }

    private static let phrases: [(String, Command)] = [
        ("new paragraph", .lineBreak("\n\n")),
        ("new line", .lineBreak("\n")),
        ("line break", .lineBreak("\n")),
        ("open quote", .openQuote),
        ("close quote", .closeQuote),
        ("nuevo parrafo", .lineBreak("\n\n")),
        ("nueva linea", .lineBreak("\n")),
        ("salto de linea", .lineBreak("\n")),
        ("abrir comillas", .openQuote),
        ("abre comillas", .openQuote),
        ("cerrar comillas", .closeQuote),
        ("cierra comillas", .closeQuote),
        ("nouveau paragraphe", .lineBreak("\n\n")),
        ("nouvelle ligne", .lineBreak("\n")),
        ("retour a la ligne", .lineBreak("\n")),
        ("saut de ligne", .lineBreak("\n")),
        ("a la ligne", .lineBreak("\n")),
        ("ouvrez les guillemets", .openQuote),
        ("ouvrir les guillemets", .openQuote),
        ("ouvre les guillemets", .openQuote),
        ("fermez les guillemets", .closeQuote),
        ("fermer les guillemets", .closeQuote),
        ("ferme les guillemets", .closeQuote)
    ]

    private static let commands = phrases.map { phrase, command in
        (words: phrase.split(separator: " ").map { scalars(String($0)) }, command: command)
    }

    /// `transcript` with its spoken formatting phrases applied.
    public static func apply(_ transcript: String) -> String {
        let chars = Array(transcript.unicodeScalars)
        var out = String.UnicodeScalarView()
        var index = 0
        // Where the "unquote" closing an open "quote" starts.
        var pendingUnquote: Int?
        let quote = scalars("quote"), unquote = scalars("unquote")
        while index < chars.count {
            let wordStart = index == 0 || !chars[index - 1].isWordCharacter
            if pendingUnquote == index {
                pendingUnquote = nil
                index = emit(&out, .closeQuote, chars, end: index + unquote.count)
                continue
            }
            if wordStart, let (command, end) = commandAt(chars, index) {
                index = emit(&out, command, chars, end: end)
                continue
            }
            if wordStart, pendingUnquote == nil, let end = matchPhrase([quote], in: chars, at: index),
               let close = unquoteAfter(chars, end, unquote) {
                pendingUnquote = close
                index = emit(&out, .openQuote, chars, end: end)
                continue
            }
            out.append(chars[index])
            index += 1
        }
        return String(out)
    }

    /// The command whose words start at `start`, and where they end.
    private static func commandAt(_ chars: [Unicode.Scalar], _ start: Int) -> (Command, Int)? {
        for (words, command) in commands {
            if let end = matchPhrase(words, in: chars, at: start) { return (command, end) }
        }
        return nil
    }

    /// Where the first whole-word "unquote" after `from` starts, when some words come between: "quote unquote
    /// experts" is a figure of speech, not a quote.
    private static func unquoteAfter(_ chars: [Unicode.Scalar], _ from: Int, _ unquote: [Unicode.Scalar]) -> Int? {
        var wordsBetween = false
        var index = from
        while index < chars.count {
            let wordStart = index == 0 || !chars[index - 1].isWordCharacter
            if wordStart, matchPhrase([unquote], in: chars, at: index) != nil {
                return wordsBetween ? index : nil
            }
            wordsBetween = wordsBetween || chars[index].isWordCharacter
            index += 1
        }
        return nil
    }

    private static func skip(_ chars: [Unicode.Scalar], _ from: Int, also: Set<Unicode.Scalar>) -> Int {
        var index = from
        while index < chars.count, chars[index].isInlineSpace || also.contains(chars[index]) { index += 1 }
        return index
    }

    /// Writes `command` and returns where the text continues.
    private static func emit(_ out: inout String.UnicodeScalarView, _ command: Command, _ chars: [Unicode.Scalar], end: Int) -> Int {
        switch command {
        case let .lineBreak(breaks):
            out.trimEnd(also: [",", ";"])
            out.append(contentsOf: breaks.unicodeScalars)
            return skip(chars, end, also: [",", ".", ";", ":"])
        case .openQuote:
            out.trimEnd()
            if let last = out.last, !"\n([\"".unicodeScalars.contains(last) { out.append(" ") }
            out.append("\"")
            return skip(chars, end, also: [",", "."])
        case .closeQuote:
            out.trimEnd(also: [","])
            out.append("\"")
            let next = skip(chars, end, also: [])
            if next < chars.count, chars[next].isWordCharacter { out.append(" ") }
            return next
        }
    }
}
