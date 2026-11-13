import Foundation

// Spoken symbols, ported from Hex (github.com/anomalyco/hex, `src/dictation/spoken_symbols.rs` at v3.4.0; MIT,
// Copyright (c) 2026 Christopher Langton), with French added in the same style.

/// Whole spoken words for punctuation and symbols become the characters, joined to their neighbours as written
/// text joins them: "hashtag release" is "#release", "my underscore variable" is "my_variable", and "done comma
/// thanks" is "done, thanks". Spanish ("arroba", "guion bajo", "punto y coma") and French ("virgule", "point
/// d'interrogation", "deux-points") words work too. Matching ignores case and accents and needs word boundaries,
/// so "commas" or "hashtags" stay as they are. The commas, periods and spaces a model puts around a spoken symbol
/// go with it.
public enum SpokenSymbols {
    /// Which neighbour a symbol attaches to.
    private enum Join {
        /// The next word: "#release".
        case next
        /// Both words: "my_variable".
        case both
        /// The previous word, with one space after: "done, thanks".
        case previous
    }

    private static let table: [(String, Unicode.Scalar, Join)] = [
        ("hashtag", "#", .next),
        ("hash sign", "#", .next),
        ("at sign", "@", .next),
        ("underscore", "_", .both),
        ("hyphen", "-", .both),
        ("slash", "/", .both),
        ("comma", ",", .previous),
        ("semicolon", ";", .previous),
        ("colon", ":", .previous),
        ("arroba", "@", .next),
        ("guion bajo", "_", .both),
        ("guion", "-", .both),
        ("punto y coma", ";", .previous),
        ("coma", ",", .previous),
        ("dos puntos", ":", .previous),
        ("arobase", "@", .next),
        ("diese", "#", .next),
        ("tiret bas", "_", .both),
        ("tiret", "-", .both),
        ("barre oblique", "/", .both),
        ("virgule", ",", .previous),
        ("point virgule", ";", .previous),
        ("point d'interrogation", "?", .previous),
        ("point d'exclamation", "!", .previous),
        ("deux-points", ":", .previous),
        ("deux points", ":", .previous)
    ]

    private static let symbols = table.map { phrase, symbol, join in
        (words: phrase.split(separator: " ").map { scalars(String($0)) }, symbol: symbol, join: join)
    }

    /// `transcript` with its spoken symbols applied.
    public static func apply(_ transcript: String) -> String {
        let chars = Array(transcript.unicodeScalars)
        var out = String.UnicodeScalarView()
        // Where the last symbol written ends, so trimming never removes it.
        var floor = 0
        var index = 0
        while index < chars.count {
            let wordStart = index == 0 || !chars[index - 1].isWordCharacter
            if wordStart, let (symbol, join, end) = symbolAt(chars, index) {
                index = emit(&out, &floor, symbol, join, chars, end)
                continue
            }
            out.append(chars[index])
            index += 1
        }
        return String(out)
    }

    /// The symbol whose words start at `start`, and where they end.
    private static func symbolAt(_ chars: [Unicode.Scalar], _ start: Int) -> (Unicode.Scalar, Join, Int)? {
        for (words, symbol, join) in symbols {
            guard let end = matchPhrase(words, in: chars, at: start) else { continue }
            if words == deuxPoints, countsPoints(chars, start, end) { continue }
            return (symbol, join, end)
        }
        return nil
    }

    // French alone: unlike "dos puntos", the two words are everyday prose ("deux points de vue", "les deux points").
    private static let deuxPoints = [scalars("deux"), scalars("points")]
    /// What follows points counted rather than ":": "deux points de vue", "deux points d'écart".
    private static let complements: Set = ["de", "d'", "du", "des"]
    /// What precedes points counted: "les deux points", "à deux points près".
    private static let counters: Set = ["les", "des", "ces", "mes", "tes", "ses", "nos", "vos", "leurs", "aux", "a", "de", "en", "par", "sur"]

    /// Whether the unhyphenated "deux points" between `start` and `end` counts points in running prose. The
    /// hyphenated "deux-points" always names the colon.
    private static func countsPoints(_ chars: [Unicode.Scalar], _ start: Int, _ end: Int) -> Bool {
        var after = end
        while after < chars.count, chars[after].isInlineSpace { after += 1 }
        var next = String.UnicodeScalarView()
        while after < chars.count, chars[after].isWordCharacter || chars[after].folded == "'" {
            next.append(chars[after].folded)
            after += 1
            if next.last == "'" { break }
        }
        var before = start
        while before > 0, chars[before - 1].isInlineSpace { before -= 1 }
        var previous: [Unicode.Scalar] = []
        while before > 0, chars[before - 1].isWordCharacter { before -= 1; previous.insert(chars[before].folded, at: 0) }
        return complements.contains(String(next)) || counters.contains(String(String.UnicodeScalarView(previous)))
    }

    private static func skip(_ chars: [Unicode.Scalar], _ from: Int) -> Int {
        var index = from
        while index < chars.count, chars[index].isInlineSpace || chars[index] == "," || chars[index] == "." { index += 1 }
        return index
    }

    /// Writes `symbol` and returns where the text continues.
    private static func emit(
        _ out: inout String.UnicodeScalarView, _ floor: inout Int, _ symbol: Unicode.Scalar, _ join: Join,
        _ chars: [Unicode.Scalar], _ end: Int
    ) -> Int {
        if join != .next { out.trimEnd(also: [","], floor: floor) }
        out.append(symbol)
        floor = out.count
        let next = skip(chars, end)
        if join == .previous, next < chars.count, !"\n,.;:!?)]\"".unicodeScalars.contains(chars[next]) { out.append(" ") }
        return next
    }
}
