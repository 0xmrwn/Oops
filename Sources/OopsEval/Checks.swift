import Foundation
import OopsCore

/// The checks code can make on an answer, before any judge.
enum Checks {
    /// `oops-eval`'s verdict in the contract's words: an alternative counts as exact.
    static func verdict(_ output: String, for item: EvalCase) -> String {
        guard let expected = item.expected else { return "unscored" }
        if sameText(output, expected) || (item.alternatives ?? []).contains(where: { sameText(output, $0) }) { return "exact" }
        if sameText(expected, item.input) { return "overcorrected" }
        return sameText(output, item.input) ? "unchanged" : "changed"
    }

    /// `answer` is the model's text after the app's cosmetic repair (its edge whitespace and line-break
    /// sequences put back, `CorrectionPolicy.restoredAnswer`) and before unsafe changes are dropped:
    /// the app's output keeps every protected span by construction, so the check is on what the model
    /// itself returned. `output` is what the app would paste.
    static func make(_ item: EvalCase, answer: String?, output: String?) -> CallRecord.Checks {
        var checks = CallRecord.Checks(valid: output != nil)
        if let answer {
            checks.protectedKept = CorrectionPolicy.protectedSpans(answer).elementsEqual(CorrectionPolicy.protectedSpans(item.input), by: sameText)
                && CorrectionPolicy.breaks(answer).count == CorrectionPolicy.breaks(item.input).count
                && CorrectionPolicy.edges(answer) == CorrectionPolicy.edges(item.input)
        }
        if let output {
            if item.isClean { checks.cleanUnchanged = sameText(output, item.input) }
            checks.langKept = Language.kept(item.input, output)
        }
        return checks
    }
}

/// English or French by function words: a score from -1 (all English) to 1 (all French). A
/// correction moves it a little; a translation swings it across. Too few function words, no score.
enum Language {
    static let english: Set = ["the", "and", "is", "are", "to", "of", "it", "you", "that", "this", "for", "with", "not", "be",
                               "have", "i", "we", "but", "can", "at", "do", "if", "my", "your", "will", "was", "what", "so",
                               "just", "in", "on", "about", "he", "she", "they", "me", "from", "or", "an", "it's", "i'm", "don't"]
    static let french: Set = ["le", "la", "les", "et", "est", "des", "un", "une", "du", "que", "qui", "pas", "pour", "dans", "je",
                              "tu", "il", "elle", "nous", "vous", "sur", "avec", "ce", "ça", "mais", "ne", "au", "aux", "mon",
                              "ton", "son", "très", "plus", "merci", "bonjour", "salut", "c'est", "j'ai", "l'", "d'", "n'", "qu'",
                              "on", "en", "se", "sa", "ses", "cette", "été", "être", "avoir", "fait", "demain", "oui", "non"]

    static func score(_ text: String) -> (value: Double, hits: Int) {
        var en = 0, fr = 0
        for raw in text.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "'" && $0 != "’" }) {
            let word = raw.replacingOccurrences(of: "’", with: "'")
            // French elision: l'équipe, d'accord, n'est.
            if let apostrophe = word.firstIndex(of: "'"), french.contains(String(word[...apostrophe])) { fr += 1; continue }
            if english.contains(word) { en += 1 }
            if french.contains(word) { fr += 1 }
        }
        let hits = en + fr
        return (hits == 0 ? 0 : Double(fr - en) / Double(hits), hits)
    }

    /// Whether the output stays in the input's language: scores within 0.5 of each other, once
    /// both texts have three function words or more.
    static func kept(_ input: String, _ output: String) -> Bool? {
        let a = score(input), b = score(output)
        guard a.hits >= 3, b.hits >= 3 else { return nil }
        return abs(a.value - b.value) <= 0.5
    }
}
