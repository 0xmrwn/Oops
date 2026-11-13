import Foundation

// What the three local cleanups share, ported from Hex (github.com/anomalyco/hex, `src/dictation/` at v3.4.0;
// MIT, Copyright (c) 2026 Christopher Langton): the accent fold of `spoken_formatting.rs` and the character
// tests its siblings repeat. Hex works on Rust `char`s, which are Unicode scalars; so does this.

extension Unicode.Scalar {
    /// Rust's `char::is_alphanumeric`: alphabetic, or any number.
    var isWordCharacter: Bool { properties.isAlphabetic || properties.numericType != nil }
    /// A space that is not a line break.
    var isInlineSpace: Bool { properties.isWhitespace && self != "\n" }

    /// `self` lowercased with accents dropped, as the phrase lists are written: "Párrafo" reads as "parrafo".
    /// Spanish and French accents fold; the typographic apostrophe reads as the plain one.
    var folded: Unicode.Scalar {
        let lower = properties.lowercaseMapping.unicodeScalars
        let single = lower.count == 1 ? lower[lower.startIndex] : self
        switch single {
        case "á", "à", "â": return "a"
        case "é", "è", "ê", "ë": return "e"
        case "í", "î", "ï": return "i"
        case "ó", "ô": return "o"
        case "ú", "ù", "û", "ü": return "u"
        case "ç": return "c"
        case "\u{2019}": return "'"
        default: return single
        }
    }
}

extension String.UnicodeScalarView {
    /// Removes trailing inline spaces and the characters in `also`, never below `floor` scalars.
    mutating func trimEnd(also: Set<Unicode.Scalar> = [], floor: Int = 0) {
        while count > floor, let last, last.isInlineSpace || also.contains(last) { removeLast() }
    }
}

/// A phrase such as ["new", "line"] found in `scalars` at `start`: words match with `folded` letters, joined by
/// whitespace, and end at a word boundary. Returns where it ends.
func matchPhrase(_ words: [[Unicode.Scalar]], in scalars: [Unicode.Scalar], at start: Int) -> Int? {
    var position = start
    for (number, word) in words.enumerated() {
        if number > 0 {
            var spaces = 0
            while position + spaces < scalars.count, scalars[position + spaces].properties.isWhitespace { spaces += 1 }
            if spaces == 0 { return nil }
            position += spaces
        }
        for expected in word {
            guard position < scalars.count, scalars[position].folded == expected else { return nil }
            position += 1
        }
    }
    if position < scalars.count, scalars[position].isWordCharacter { return nil }
    return position
}

func scalars(_ word: String) -> [Unicode.Scalar] { Array(word.unicodeScalars) }
