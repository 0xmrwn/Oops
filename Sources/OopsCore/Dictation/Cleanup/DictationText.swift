import Foundation
import NaturalLanguage

/// The three small cleanups' switches, all off by default.
public struct SmallCleanups: Equatable, Sendable {
    public var fillers: Bool
    public var formatting: Bool
    public var symbols: Bool

    public init(fillers: Bool = false, formatting: Bool = false, symbols: Bool = false) {
        self.fillers = fillers; self.formatting = formatting; self.symbols = symbols
    }

    public static let off = SmallCleanups()
}

/// A transcript's way to the caret before any model rewrites it: the vocabulary first, then the small cleanups. The
/// model cleanup, when it runs, comes after both, and anything that flattens line breaks (a terminal) after that.
public enum DictationText {
    /// `transcript` with the vocabulary's fuzzy replacement, for an engine that took no list of its own, then the
    /// small cleanups that are on. Fuzzy replacement re-joins words with single spaces, so it runs before spoken
    /// formatting writes line breaks. Fillers go only in English and French (`language` without its region). With
    /// no language chosen (nil or "auto"), the engine's `detected` one decides, else the transcript's own, read
    /// locally; unsure means no filler removal. With nothing to do, the transcript comes back byte for byte.
    public static func prepare(_ transcript: String, vocabulary: VocabularyDelivery?, cleanups: SmallCleanups, language: String?,
                               detected: String? = nil) -> String {
        var text = transcript
        if case let .fuzzyReplacement(terms)? = vocabulary, !terms.isEmpty { text = FuzzyReplacement.apply(text, terms: terms) }
        var base = language.map(baseCode)
        if base == nil || base == "auto" { base = detected.map(baseCode) ?? (cleanups.fillers ? fillerLanguage(of: text) : nil) }
        let fillers = cleanups.fillers && base.map(FillerWords.applies(to:)) == true
        return TranscriptCleanup.apply(text, fillers: fillers, formatting: cleanups.formatting, symbols: cleanups.symbols)
    }

    private static func baseCode(_ language: String) -> String {
        String(language.prefix { $0 != "-" && $0 != "_" }).lowercased()
    }

    /// The filler-supporting language `text` is written in, or nil when it is neither or the guess is weak. Apple's
    /// recognizer runs on-device in a few milliseconds and, held to English and French, only has to tell those apart.
    static func fillerLanguage(of text: String, floor: Double = 0.8) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = [.english, .french]
        recognizer.processString(text)
        guard let best = recognizer.languageHypotheses(withMaximum: 1).first, best.value >= floor else { return nil }
        return best.key.rawValue
    }
}
