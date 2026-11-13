import Foundation

// Remove filler words, ported from Hex (github.com/anomalyco/hex, `src/dictation/filler_words.rs` at v3.4.0; MIT,
// Copyright (c) 2026 Christopher Langton), with French added in the same style.

/// The hesitations a model writes down verbatim ("um", "uh", French "euh") leave the transcript, with no model
/// involved. A filler matches as a whole word, lowercase or with only its first letter capitalised, so "umbrella",
/// "ahead", "error", "Uhura", "uh-huh" and "ER" stay as they are. The comma or ellipsis that comes with a filler
/// goes with it, the spaces around it close up, and a capitalised filler that started a sentence hands its
/// capital to the next word. Line breaks are kept.
public enum FillerWords {
    // Longest first: "umm" must win over "um".
    static let english = ["umm", "um", "uhh", "uh", "erm", "er", "ah"]
    static let french = ["euh", "heu", "bah", "hum"]
    private static let fillers = (english + french).map { Array($0.unicodeScalars) }

    /// Whether a dictation in `language` (a code without a region) loses its fillers. "er" and "um" are ordinary
    /// German and Portuguese words, so only English and French do; "auto" and every other language keep their
    /// transcripts as heard.
    public static func applies(to language: String) -> Bool {
        language == "en" || language == "fr"
    }

    /// `transcript` without its filler words.
    public static func apply(_ transcript: String) -> String {
        let chars = Array(transcript.unicodeScalars)
        var out = String.UnicodeScalarView()
        // A filler was just removed: the next text decides the spacing.
        var removed = false
        var capitalize = false
        var index = 0
        while index < chars.count {
            if let end = fillerEnd(chars, at: index) {
                out.trimEnd()
                if !removed { capitalize = chars[index].properties.isUppercase && sentenceStart(out) }
                index = afterFiller(chars, end)
                removed = true
                continue
            }
            let c = chars[index]
            index += 1
            if removed {
                if c.isInlineSpace { continue }
                if c == "\n" {
                    removed = false
                    capitalize = false
                    out.append(c)
                    continue
                }
                if ".!?,".unicodeScalars.contains(c), sentenceStart(out) { continue }
                removed = false
                let closing = ".,;:!?)]}\u{201D}\u{2019}\u{2026}".unicodeScalars.contains(c)
                    || (c == "\"" && !(index < chars.count && chars[index].isWordCharacter))
                if closing {
                    out.trimEnd(also: [","])
                    capitalize = false
                } else {
                    if needsSpace(out) { out.append(" ") }
                    if capitalize {
                        capitalize = false
                        out.append(contentsOf: c.properties.uppercaseMapping.unicodeScalars)
                        continue
                    }
                }
            }
            out.append(c)
        }
        if removed { out.trimEnd(also: [","]) }
        return String(out)
    }

    private static func joinsWord(_ c: Unicode.Scalar) -> Bool {
        c.isWordCharacter || c == "-" || c == "'" || c == "\u{2019}"
    }

    /// Where the filler starting at `start` ends, if one does.
    private static func fillerEnd(_ chars: [Unicode.Scalar], at start: Int) -> Int? {
        if start > 0, joinsWord(chars[start - 1]) { return nil }
        for word in fillers {
            let end = start + word.count
            guard end <= chars.count else { continue }
            let matches = word.indices.allSatisfy { number in
                let c = chars[start + number], expected = word[number]
                return c == expected || (number == 0 && c.value == expected.value - 32)
            }
            let ends = end == chars.count || !joinsWord(chars[end])
            if matches, ends { return end }
        }
        return nil
    }

    /// Where the text continues after a filler ending at `end`, past its own comma or ellipsis.
    private static func afterFiller(_ chars: [Unicode.Scalar], _ end: Int) -> Int {
        var index = skipSpaces(chars, end)
        if index < chars.count {
            if chars[index] == "," || chars[index] == "\u{2026}" {
                index += 1
            } else if chars[index] == ".", index + 2 < chars.count, chars[index + 1] == ".", chars[index + 2] == "." {
                index += 3
            }
        }
        return skipSpaces(chars, index)
    }

    private static func skipSpaces(_ chars: [Unicode.Scalar], _ from: Int) -> Int {
        var index = from
        while index < chars.count, chars[index].isInlineSpace { index += 1 }
        return index
    }

    private static func sentenceStart(_ out: String.UnicodeScalarView) -> Bool {
        guard let last = out.last else { return true }
        return ".!?\n".unicodeScalars.contains(last)
    }

    private static func needsSpace(_ out: String.UnicodeScalarView) -> Bool {
        guard let last = out.last else { return false }
        if "\n([{\u{201C}\u{2018}".unicodeScalars.contains(last) { return false }
        if last == "\"" {
            let before = out.dropLast().last
            return before.map { !$0.properties.isWhitespace } ?? false
        }
        return true
    }
}
