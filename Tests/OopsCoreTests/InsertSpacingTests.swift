import XCTest
@testable import OopsCore

/// Carried over from Hex's `src/paste.rs` tests (1b82cc0) for the rules ported in `InsertSpacing.swift`, then
/// the rules applied to a field: its start, after a word, before punctuation, a selection, and a terminal.
final class InsertSpacingTests: XCTestCase {
    // joins_contiguous_dictation_with_sentence_aware_spacing
    func testJoinsContiguousDictationWithSentenceAwareSpacing() {
        XCTAssertEqual(InsertSpacing.join("Because if I don't do that,", "And if you see it."), " and if you see it.")
        XCTAssertEqual(InsertSpacing.join("And if you see it.", "well, that works."), " Well, that works.")
        XCTAssertEqual(InsertSpacing.join("Already spaced. ", "Next sentence."), "Next sentence.")
        XCTAssertEqual(InsertSpacing.join("Hello", ", world."), ", world.")
    }

    // smart_spacing_adds_a_space_only_where_one_belongs
    func testSmartSpacingAddsASpaceOnlyWhereOneBelongs() {
        for previous: Character in ["a", "Z", "7", ".", "?", ")", "”"] {
            XCTAssertTrue(InsertSpacing.needsLeadingSpace(previous, "in progress"), "\(previous)")
        }
        for previous: Character in ["@", "$", "#", "/", "-", "(", "“", " ", "\n", "\t"] {
            XCTAssertFalse(InsertSpacing.needsLeadingSpace(previous, "in progress"), "\(previous)")
        }
        XCTAssertFalse(InsertSpacing.needsLeadingSpace("a", ""))
        XCTAssertFalse(InsertSpacing.needsLeadingSpace("a", " already spaced"))
        XCTAssertFalse(InsertSpacing.needsLeadingSpace("a", ", then more"))
    }

    // preserves_likely_proper_nouns_mid_sentence
    func testPreservesLikelyProperNounsMidSentence() {
        XCTAssertEqual(InsertSpacing.join("Open", "GitHub next."), " GitHub next.")
        XCTAssertEqual(InsertSpacing.join("Message", "Slack now."), " Slack now.")
    }

    private func caret(_ location: Int) -> NSRange { NSRange(location: location, length: 0) }

    func testTheStartOfAFieldTakesTheTextAsItIs() {
        XCTAssertEqual(InsertSpacing.shaped("Hello", in: "", selection: caret(0)), "Hello")
        XCTAssertEqual(InsertSpacing.shaped("Hello", in: "world", selection: caret(0)), "Hello")
        XCTAssertEqual(InsertSpacing.shaped("Hello", in: "Type a message", selection: caret(14), placeholders: ["Type a message"]), "Hello",
                       "a field showing only its placeholder is empty")
    }

    func testAfterAWordOneSpaceGoesIn() {
        XCTAssertEqual(InsertSpacing.shaped("there", in: "Hello", selection: caret(5)), " there")
        XCTAssertEqual(InsertSpacing.shaped("there", in: "Hello world", selection: caret(5)), " there", "mid-text, the caret's left side counts")
        XCTAssertEqual(InsertSpacing.shaped("there", in: "Hello ", selection: caret(6)), "there", "already spaced")
        XCTAssertEqual(InsertSpacing.shaped("there", in: "Merci 🙏", selection: caret(8)), "there", "after a symbol")
    }

    func testBeforePunctuationNoSpaceGoesIn() {
        XCTAssertEqual(InsertSpacing.shaped(", world.", in: "Hello", selection: caret(5)), ", world.")
        XCTAssertEqual(InsertSpacing.shaped("world", in: "Hello.", selection: caret(5)), " world", "the caret before a full stop")
    }

    func testASelectionIsReplacedAsItIs() {
        XCTAssertEqual(InsertSpacing.shaped("minutes", in: "send the notes today", selection: NSRange(location: 9, length: 5)), "minutes")
    }

    func testAFieldThatCantBeReadTakesTheTextAsItIs() {
        XCTAssertEqual(InsertSpacing.shaped("Hello", in: nil, selection: nil), "Hello")
        XCTAssertEqual(InsertSpacing.shaped("Hello", in: "short", selection: caret(40)), "Hello", "a caret past the end")
    }

    func testTheNextDictationJoinsThePreviousOne() {
        XCTAssertEqual(InsertSpacing.shaped("And if you see it.", in: "Because if I don't do that,", selection: caret(27),
                                            previous: "Because if I don't do that,"), " and if you see it.")
        XCTAssertEqual(InsertSpacing.shaped("well, that works.", in: "Notes: And if you see it.", selection: caret(25),
                                            previous: " And if you see it."), " Well, that works.")
        // Text typed since is no continuation: only the character before the caret counts.
        XCTAssertEqual(InsertSpacing.shaped("And more", in: "And if you see it. Typed", selection: caret(24),
                                            previous: "And if you see it."), " And more")
    }

    func testATerminalGetsOneLine() {
        XCTAssertEqual(TextInsertion.oneLine("First line.\nSecond line."), "First line. Second line.")
        XCTAssertEqual(TextInsertion.oneLine("One.\r\n\r\nTwo. \n  Three."), "One. Two. Three.")
        XCTAssertEqual(TextInsertion.oneLine("a\u{2028}b\u{2029}c"), "a b c")
        XCTAssertEqual(TextInsertion.oneLine("No break, two sentences. Kept."), "No break, two sentences. Kept.")
    }
}
