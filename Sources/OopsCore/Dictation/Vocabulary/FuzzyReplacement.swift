import Foundation

// Fuzzy replacement of vocabulary terms after transcription, ported from Handy (github.com/cjpais/handy,
// `src-tauri/src/audio_toolkit/text.rs` at 73cc857; MIT, Copyright (c) 2025 CJ Pais): `apply_custom_words` and its
// helpers. Handy's filler, stutter and language-evidence code in that file is not part of it. Handy's `natural`
// crate Soundex and `strsim` Levenshtein distance are written out below.

/// Corrects words in a transcript by matching them against the user's terms with Levenshtein distance, Soundex
/// phonetic matching and n-grams of up to three words ("Charge B" is "ChargeBee"). For engines that take no
/// vocabulary themselves. The matcher is limited to ASCII terms: whitespace tokenization and Soundex do not suit
/// other scripts, so those terms are left to engines that take them natively.
public enum FuzzyReplacement {
    /// Handy's default `word_correction_threshold`: the highest score a match may have (0 is exact).
    public static let defaultThreshold = 0.18

    private struct MatchKey {
        let wordIndex: Int
        let key: String
    }

    /// `text` with words matching `terms` replaced by them, case pattern and surrounding punctuation kept. Words
    /// are rejoined with single spaces.
    public static func apply(_ text: String, terms: [String], threshold: Double = defaultThreshold) -> String {
        if terms.isEmpty { return text }
        let keys = terms.enumerated().flatMap { matchKeys($1, wordIndex: $0) }
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        var result: [String] = []
        var index = 0
        while index < words.count {
            var best: (count: Int, replacement: String, score: Double)?
            // Up to three words, taking the closest match: longest-first could consume a following ordinary word
            // that shares a Soundex code ("Charge B, che" matching "ChargeBee").
            for count in stride(from: 3, through: 1, by: -1) where index + count <= words.count {
                let ngram = Array(words[index ..< index + count])
                // Do not consume across a punctuation boundary: in "Charge B, che" the comma closes "B,".
                if ngram.dropLast().contains(where: { !extractPunctuation($0).suffix.isEmpty }) { continue }
                if let (replacement, score) = bestMatch(buildNgram(ngram), terms, keys, threshold),
                   best.map({ score < $0.score }) ?? true {
                    best = (count, replacement, score)
                }
            }
            if let best {
                let ngram = Array(words[index ..< index + best.count])
                let corrected = preserveCasePattern(ngram[0], best.replacement)
                result.append(extractPunctuation(ngram[0]).prefix + corrected + extractPunctuation(ngram[best.count - 1]).suffix)
                index += best.count
            } else {
                result.append(words[index])
                index += 1
            }
        }
        return result.joined(separator: " ")
    }

    // MARK: Matching

    /// Strips punctuation from each word, lowercases and joins without spaces, so "Charge B" matches "ChargeBee".
    static func buildNgram(_ words: [String]) -> String {
        words.map(buildMatchKey).joined()
    }

    static func buildMatchKey(_ word: String) -> String {
        var key = String.UnicodeScalarView()
        for scalar in word.unicodeScalars where scalar.isWordCharacter { key.append(contentsOf: scalar.properties.lowercaseMapping.unicodeScalars) }
        return String(key)
    }

    private static func isSupportedKey(_ key: String) -> Bool {
        !key.isEmpty && key.unicodeScalars.allSatisfy { $0.isASCII && ($0.properties.isAlphabetic || ("0" ... "9").contains($0)) }
    }

    private static func supportsSoundex(_ key: String) -> Bool {
        !key.isEmpty && key.unicodeScalars.allSatisfy { $0.isASCII && $0.properties.isAlphabetic }
    }

    private static func matchKeys(_ word: String, wordIndex: Int) -> [MatchKey] {
        let primary = buildMatchKey(word)
        var keys: [MatchKey] = []
        if isSupportedKey(primary) { keys.append(MatchKey(wordIndex: wordIndex, key: primary)) }
        if word.contains("&") {
            let expanded = buildMatchKey(word.replacingOccurrences(of: "&", with: " and "))
            if isSupportedKey(expanded), expanded != primary { keys.append(MatchKey(wordIndex: wordIndex, key: expanded)) }
        }
        return keys
    }

    /// The best matching term for a candidate, and its score, if any is below `threshold`.
    private static func bestMatch(_ candidate: String, _ terms: [String], _ keys: [MatchKey], _ threshold: Double) -> (String, Double)? {
        let candidateLength = candidate.unicodeScalars.count
        if !isSupportedKey(candidate) || candidateLength > 50 { return nil }
        var best: String?
        var bestScore = Double.greatestFiniteMagnitude
        for entry in keys {
            // Skip lengths too far apart (an optimization that also stops "openaigpt" matching "openai"): at most 25%,
            // and at least 2 characters of difference are allowed.
            let termLength = entry.key.unicodeScalars.count
            let difference = Double(abs(candidateLength - termLength))
            let maxLength = Double(max(candidateLength, termLength))
            if difference > max(maxLength * 0.25, 2) { continue }
            let levenshteinScore = maxLength > 0 ? Double(levenshtein(candidate, entry.key)) / maxLength : 1
            // Soundex is an English/ASCII phonetic algorithm: numeric terms can still use edit distance but get
            // no phonetic boost.
            let phonetic = supportsSoundex(candidate) && supportsSoundex(entry.key) && soundex(candidate) == soundex(entry.key)
            let score = phonetic ? levenshteinScore * 0.3 : levenshteinScore
            if score < threshold, score < bestScore {
                best = terms[entry.wordIndex]
                bestScore = score
            }
        }
        return best.map { ($0, bestScore) }
    }

    /// Keeps the case pattern of the original word: all capitals stay all capitals, a capital first letter stays.
    static func preserveCasePattern(_ original: String, _ replacement: String) -> String {
        if original.unicodeScalars.allSatisfy(\.properties.isUppercase) { return replacement.uppercased() }
        if original.unicodeScalars.first?.properties.isUppercase == true, let first = replacement.unicodeScalars.first {
            let upper = first.properties.uppercaseMapping.unicodeScalars.first ?? first
            var scalars = String.UnicodeScalarView([upper])
            scalars.append(contentsOf: replacement.unicodeScalars.dropFirst())
            return String(scalars)
        }
        return replacement
    }

    /// The punctuation before the first and after the last letter or digit of a word.
    static func extractPunctuation(_ word: String) -> (prefix: String, suffix: String) {
        let scalars = Array(word.unicodeScalars)
        guard let first = scalars.firstIndex(where: \.isWordCharacter), let last = scalars.lastIndex(where: \.isWordCharacter) else {
            return ("", "")
        }
        return (String(String.UnicodeScalarView(scalars[..<first])), String(String.UnicodeScalarView(scalars[(last + 1)...])))
    }

    // MARK: Distances

    /// American Soundex: the first letter and up to three digits, as the `natural` crate encodes for comparison.
    static func soundex(_ word: String) -> String {
        func code(_ c: Character) -> Character? {
            switch c {
            case "b", "f", "p", "v": "1"
            case "c", "g", "j", "k", "q", "s", "x", "z": "2"
            case "d", "t": "3"
            case "l": "4"
            case "m", "n": "5"
            case "r": "6"
            default: nil
            }
        }
        let letters = word.lowercased().filter { $0.isASCII && $0.isLetter }
        guard let first = letters.first else { return "" }
        var encoded = String(first).uppercased()
        var previous = code(first)
        for letter in letters.dropFirst() {
            let current = code(letter)
            // H and W do not separate letters with the same code; vowels do.
            if letter == "h" || letter == "w" { continue }
            if let current, current != previous { encoded.append(current) }
            previous = current
            if encoded.count == 4 { break }
        }
        return encoded.padding(toLength: 4, withPad: "0", startingAt: 0)
    }

    static func levenshtein(_ left: String, _ right: String) -> Int {
        let a = Array(left.unicodeScalars), b = Array(right.unicodeScalars)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var row = Array(0 ... b.count)
        for i in 1 ... a.count {
            var diagonal = row[0]
            row[0] = i
            for j in 1 ... b.count {
                let above = row[j]
                row[j] = min(above + 1, row[j - 1] + 1, diagonal + (a[i - 1] == b[j - 1] ? 0 : 1))
                diagonal = above
            }
        }
        return row[b.count]
    }
}
