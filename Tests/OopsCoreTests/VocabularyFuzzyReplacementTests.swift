import XCTest
@testable import OopsCore

/// Handy's custom word tests (`src-tauri/src/audio_toolkit/text.rs` at 73cc857), each under its upstream name in the
/// Swift style. Not ported: its filler word, stutter and language-evidence tests, which are not part of the matcher.
final class VocabularyFuzzyReplacementTests: XCTestCase {
    func apply(_ text: String, _ terms: [String], _ threshold: Double = 0.5) -> String {
        FuzzyReplacement.apply(text, terms: terms, threshold: threshold)
    }

    func testApplyCustomWordsExactMatch() {
        XCTAssertEqual(apply("hello world", ["Hello", "World"]), "Hello World")
    }

    func testApplyCustomWordsFuzzyMatch() {
        XCTAssertEqual(apply("helo wrold", ["hello", "world"]), "hello world")
    }

    func testPreserveCasePattern() {
        XCTAssertEqual(FuzzyReplacement.preserveCasePattern("HELLO", "world"), "WORLD")
        XCTAssertEqual(FuzzyReplacement.preserveCasePattern("Hello", "world"), "World")
        XCTAssertEqual(FuzzyReplacement.preserveCasePattern("hello", "WORLD"), "WORLD")
    }

    func testExtractPunctuation() {
        func parts(_ word: String) -> [String] {
            let (prefix, suffix) = FuzzyReplacement.extractPunctuation(word)
            return [prefix, suffix]
        }
        XCTAssertEqual(parts("hello"), ["", ""])
        XCTAssertEqual(parts("!hello?"), ["!", "?"])
        XCTAssertEqual(parts("...hello..."), ["...", "..."])
    }

    func testExtractPunctuationUsesUnicodeBoundaries() {
        func parts(_ word: String) -> [String] {
            let (prefix, suffix) = FuzzyReplacement.extractPunctuation(word)
            return [prefix, suffix]
        }
        XCTAssertEqual(parts("你好。"), ["", "。"])
        XCTAssertEqual(parts("「你好」"), ["「", "」"])
        XCTAssertEqual(parts("你好！"), ["", "！"])
    }

    func testEmptyCustomWords() {
        XCTAssertEqual(apply("hello world", []), "hello world")
    }

    func testApplyCustomWordsNgramTwoWords() {
        let result = apply("il cui nome è Charge B, che permette", ["ChargeBee"])
        XCTAssertTrue(result.contains("ChargeBee,"), "unexpected result: \(result)")
        XCTAssertFalse(result.contains("Charge B"))
    }

    func testApplyCustomWordsNgramThreeWords() {
        XCTAssertTrue(apply("use Chat G P T for this", ["ChatGPT"]).contains("ChatGPT"))
    }

    func testApplyCustomWordsPrefersLongerNgram() {
        XCTAssertEqual(apply("Open AI GPT model", ["OpenAI", "GPT"]), "OpenAI GPT model")
    }

    func testApplyCustomWordsNgramPreservesCase() {
        XCTAssertTrue(apply("CHARGE B is great", ["ChargeBee"]).contains("CHARGEBEE"))
    }

    func testApplyCustomWordsNgramWithSpacesInCustom() {
        // A term with a space matches against split words too.
        XCTAssertEqual(apply("using Mac Book Pro", ["MacBook Pro"]), "using MacBook Pro")
    }

    func testApplyCustomWordsTrailingNumberNotDoubled() {
        // Trailing digits are not counted twice, by the n-gram key and by the punctuation suffix.
        let result = apply("use GPT4 for this", ["GPT-4"])
        XCTAssertFalse(result.contains("GPT-44"), "got double-counted result: \(result)")
    }

    func testApplyCustomWordsMatchesAmpersandWord() {
        XCTAssertEqual(apply("send it to RD for review", ["R&D"], 0.18), "send it to R&D for review")
    }

    func testApplyCustomWordsMatchesSpokenAmpersandWord() {
        XCTAssertEqual(apply("send it to R and D for review", ["R&D"], 0.18), "send it to R&D for review")
    }

    func testApplyCustomWordsPreservesAmpersandWord() {
        XCTAssertEqual(apply("send it to R&D for review", ["R&D"], 0.18), "send it to R&D for review")
    }

    func testApplyCustomWordsHandlesUnicodePunctuation() {
        XCTAssertEqual(apply("「Handee。」", ["Handy"]), "「Handy。」")
    }

    func testApplyCustomWordsSkipsCjkFuzzyMatching() {
        XCTAssertEqual(apply("你好。", ["你号"], 1.0), "你好。")
    }

    // MARK: The pieces Handy takes from crates

    func testSoundexGroupsWordsThatSoundAlike() {
        XCTAssertEqual(FuzzyReplacement.soundex("Robert"), "R163")
        XCTAssertEqual(FuzzyReplacement.soundex("Rupert"), "R163")
        XCTAssertEqual(FuzzyReplacement.soundex("Tymczak"), "T522")
        XCTAssertEqual(FuzzyReplacement.soundex("Pfister"), "P236")
        XCTAssertEqual(FuzzyReplacement.soundex("Ashcraft"), "A261")
        XCTAssertEqual(FuzzyReplacement.soundex("hello"), FuzzyReplacement.soundex("helo"))
        XCTAssertEqual(FuzzyReplacement.soundex("a"), "A000")
    }

    func testLevenshteinCountsEdits() {
        XCTAssertEqual(FuzzyReplacement.levenshtein("kitten", "sitting"), 3)
        XCTAssertEqual(FuzzyReplacement.levenshtein("", "abc"), 3)
        XCTAssertEqual(FuzzyReplacement.levenshtein("same", "same"), 0)
    }
}
