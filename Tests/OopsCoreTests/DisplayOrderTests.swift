import Foundation
@testable import OopsCore
import XCTest

final class DisplayOrderTests: XCTestCase {
    let typed = "ثم صحح الجزء التاني @Alice Martin من الخطة"
    // Chromium's text markers for the same field: the "@" laid out after the Latin name.
    let shown = "ثم صحح الجزء التاني Alice Martin@ من الخطة"

    func testRunsMovedInRightToLeftText() {
        XCTAssertTrue(DisplayOrder.reordered(shown, of: typed))
        // Whole lines laid out in another order still hold the same characters.
        XCTAssertTrue(DisplayOrder.reordered(" من الخطةAlice Martinثم صحح الجزء التاني @", of: typed))
    }

    func testSameOrDifferentTextIsNoReorder() {
        XCTAssertFalse(DisplayOrder.reordered(typed, of: typed))
        XCTAssertFalse(DisplayOrder.reordered(shown.replacingOccurrences(of: "الخطة", with: "الخطه"), of: typed))
        XCTAssertFalse(DisplayOrder.reordered(shown + " ", of: typed))
        // Left-to-right text is never laid out in another order: a permutation there is a real change.
        XCTAssertFalse(DisplayOrder.reordered("fix teh smal @Alice", of: "fix teh @Alice smal"))
    }

    func testMovedRunsAwayFromASpan() {
        let pasted = (typed as NSString).range(of: "الخطة")
        XCTAssertTrue(DisplayOrder.reordered(shown, of: typed, awayFrom: pasted))
        // The moved run takes in the pasted word: its offsets can't be trusted.
        XCTAssertFalse(DisplayOrder.reordered(" من الخطةAlice Martinثم صحح الجزء التاني @", of: typed, awayFrom: pasted))
        let mention = (typed as NSString).range(of: "@Alice")
        XCTAssertFalse(DisplayOrder.reordered(shown, of: typed, awayFrom: mention))
        // A misplaced paste changes characters, not just their order.
        let misplaced = "ثم صحح الجزء الخطة @Alice Martin من الخطة"
        XCTAssertFalse(DisplayOrder.reordered(misplaced, of: typed, awayFrom: pasted))
    }

    func testAMovedRunKeepsItsLetters() {
        // Another word's letters permuted away from the paste is a change, not display order.
        let next = "مرحبا small and form @Bob"
        XCTAssertFalse(DisplayOrder.reordered("مرحبا small and from Bob@", of: next, awayFrom: NSRange(location: 6, length: 5)))
        XCTAssertTrue(DisplayOrder.reordered("مرحبا small and form Bob@", of: next, awayFrom: NSRange(location: 6, length: 5)))
    }

    func testAMovedRunChangesNothingProtected() {
        // A backtick moved away from the paste changes which word is code.
        let next = "مرحبا small `code` text"
        XCTAssertFalse(DisplayOrder.reordered("مرحبا small code `text`", of: next, awayFrom: NSRange(location: 6, length: 5)))
        // A mention's "@" from one end of the name to the other is display order.
        XCTAssertTrue(DisplayOrder.plainMove("Alice Martin@", "@Alice Martin"))
        XCTAssertFalse(DisplayOrder.plainMove("Alice @Martin", "@Alice Martin"))
    }

    func testMovedParagraphNeedsCopyProof() {
        let draft = "مرحبا smal first\nsecond last", next = "مرحبا small first\nsecond last"
        let reading = "مرحبا small firstsecond\n last", pasted = NSRange(location: 6, length: 5)
        XCTAssertFalse(DisplayOrder.reordered(reading, of: next, awayFrom: pasted))
        XCTAssertFalse(DisplayOrder.confirms(reading, next: next, draft: draft, pasted: pasted, distinct: false))
        XCTAssertFalse(DisplayOrder.copied(reading, matches: next))
    }

    func testMovedRunsAreMinimal() {
        // Two separate moves, each closed: a span between them is untouched by either.
        let typed2 = "@Bob مرحبا تحديت الخطة @Alice"
        let shown2 = "Bob@ مرحبا تحديت الخطة Alice@"
        XCTAssertTrue(DisplayOrder.reordered(shown2, of: typed2, awayFrom: (typed2 as NSString).range(of: "تحديت")))
        XCTAssertEqual(DisplayOrder.moved(shown2, of: typed2), [NSRange(location: 0, length: 4), NSRange(location: 23, length: 6)])
    }

    func testConfirmsAPasteInDisplayOrder() {
        let draft = "مرحبا بالفريق، تم تحديت الخطة @Alice Martin واصبحت الأولويات واضحة الآن"
        let next = "مرحبا بالفريق، تم تحديت الخطة @Alice Martin وأصبحت الأولويات واضحة الآن"
        let pasted = (next as NSString).range(of: "وأصبحت")
        // A wrapped line in display order: the "@" moved, and the space at the wrap moved beside it,
        // taking in the pasted word's offsets.
        let shown = "مرحبا بالفريق، تم تحديت الخطة Alice Martin@  وأصبحت الأولوياتواضحة الآن"
        XCTAssertTrue(DisplayOrder.confirms(next, next: next, draft: draft, pasted: pasted, distinct: false))
        XCTAssertFalse(DisplayOrder.confirms(shown, next: next, draft: draft, pasted: pasted, distinct: false))
        XCTAssertTrue(DisplayOrder.confirms(shown, next: next, draft: draft, pasted: pasted, distinct: true))
        // Nothing pasted: the draft in display order still holds the old word.
        let unchanged = shown.replacingOccurrences(of: "وأصبحت", with: "واصبحت")
        XCTAssertFalse(DisplayOrder.confirms(unchanged, next: next, draft: draft, pasted: pasted, distinct: true))
        // Pasted beside the word instead of over it.
        let inserted = "مرحبا بالفريق، تم تحديت الخطة Alice Martin@  وأصبحتواصبحت الأولوياتواضحة الآن"
        XCTAssertFalse(DisplayOrder.confirms(inserted, next: next, draft: draft, pasted: pasted, distinct: true))
    }

    func testAFixThatOnlyMovesLettersNeedsTheTextAsTyped() {
        // "تحديت" → "تحيدت" swaps two letters: the draft in display order holds the same characters as
        // the fixed text, so only an exact reading, or one moved away from the paste, confirms it.
        let draft = "تحيدت الخطة @Bob", next = "تحديت الخطة @Bob"
        let pasted = NSRange(location: 0, length: 5)
        XCTAssertFalse(DisplayOrder.confirms("تحيدت الخطة Bob@", next: next, draft: draft, pasted: pasted, distinct: true))
        XCTAssertTrue(DisplayOrder.confirms("تحديت الخطة Bob@", next: next, draft: draft, pasted: pasted, distinct: true))
    }

    func testBaseOfAPartialReplacement() {
        let draft = "تحديت الخطة @Bob واصبحت", next = "تحديت الخطة @Bob وأصبحت"
        XCTAssertEqual(DisplayOrder.base(of: next, among: [draft, next], ordered: false), next)
        XCTAssertEqual(DisplayOrder.base(of: "تحديت الخطة Bob@ وأصبحت", among: [draft, next], ordered: true), next)
        XCTAssertNil(DisplayOrder.base(of: "تحديت الخطة Bob@ وأصبحت", among: [draft, next], ordered: false))
        // An anagram fix (teh → the) in mixed-direction text: a reading in display order matches both.
        let before = "مرحبا teh @Bob", after = "مرحبا the @Bob"
        XCTAssertNil(DisplayOrder.base(of: "مرحبا the Bob@", among: [before, after], ordered: true))
        XCTAssertEqual(DisplayOrder.base(of: after, among: [before, after], ordered: true), after)
        XCTAssertNil(DisplayOrder.base(of: "something else", among: [before, after], ordered: true))
    }

    func testDistinctIsQuickOnALongDraft() {
        // A long word in a long draft: a sliding count, not a sort of every window.
        let word = String(repeating: "ب", count: 250) + String(repeating: "ت", count: 250)
        let text = String(repeating: "ا", count: 15_000) + word + String(repeating: "ا", count: 500)
        let start = Date()
        XCTAssertTrue(DisplayOrder.distinct([word], in: text))
        XCTAssertFalse(DisplayOrder.distinct([word], in: text + word))
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    }

    func testCopiedText() {
        XCTAssertTrue(DisplayOrder.copied("ثم صحح 🎉 من", matches: "ثم صحح \u{FFFC} من"))
        XCTAssertTrue(DisplayOrder.copied("ثم صحح  من", matches: "ثم صحح \u{FFFC} من"))
        XCTAssertTrue(DisplayOrder.copied("same", matches: "same"))
        XCTAssertFalse(DisplayOrder.copied("مرحبا`smal` code", matches: "مرحبا smal `code`"))
        // A paragraph break moved shows, even where Trix's copy of a chip would have one.
        XCTAssertFalse(DisplayOrder.copied("مرحبا\nsmall other @Bob", matches: "مرحبا small\nother @Bob"))
        XCTAssertFalse(DisplayOrder.copied("التاني \n@Alice Martin\n من", matches: "التاني @Alice Martin\u{FFFC} من"))
        XCTAssertFalse(DisplayOrder.copied("التاني Alice Martin@ من", matches: "التاني @Alice Martin\u{FFFC} من"))
        XCTAssertFalse(DisplayOrder.copied("ثم صحح 🎉 من x", matches: "ثم صحح \u{FFFC} من"))
        XCTAssertTrue(DisplayOrder.copied("مرحبا smal team photo other", matches: "مرحبا smal \u{FFFC} other"))
        // A space moved onto a mention sign joins it to the next word: a new mention.
        XCTAssertFalse(DisplayOrder.copied("مرحبا  @smal", matches: "مرحبا @ smal"))
        // A draft ending with an image: its alt text ends the copy.
        XCTAssertTrue(DisplayOrder.copied("مرحبا smal 🎉", matches: "مرحبا smal \u{FFFC}"))
        XCTAssertTrue(DisplayOrder.copied("مرحبا smal", matches: "مرحبا smal \u{FFFC}"))
        // Alt text is short: more than that after an image is text the draft doesn't have.
        XCTAssertFalse(DisplayOrder.copied("مرحبا smal 🎉 " + String(repeating: "more ", count: 8), matches: "مرحبا smal \u{FFFC}"))
    }

    func testCopiedTextKeepsWhatIsProtected() {
        // A line break moved out of inline code makes it code.
        XCTAssertFalse(DisplayOrder.copied("مرحبا `smal code`\n", matches: "مرحبا `smal\ncode` "))
        XCTAssertFalse(DisplayOrder.copied("مرحبا `small` code", matches: "مرحبا small `code`"))
    }

    func testCopiedTextKeepsBlankParagraphsInPlace() {
        let expected = "مرحبا small\n\none\ntwo @Bob"
        XCTAssertFalse(DisplayOrder.copied("مرحبا small\none\n\ntwo @Bob", matches: expected))
        XCTAssertFalse(DisplayOrder.copied("مرحبا small\none\ntwo @Bob", matches: expected))
        XCTAssertTrue(DisplayOrder.copied("مرحبا small\r\n\r\none\r\ntwo @Bob", matches: expected))
        // Chromium's selection can include empty blocks its Accessibility text leaves out.
        XCTAssertTrue(DisplayOrder.copied(expected, matches: "مرحبا small\none\ntwo @Bob"))
        XCTAssertFalse(DisplayOrder.copied("مرحبا small\none\n\ntwo @Bob 🎉", matches: expected + " \u{FFFC}"))
        XCTAssertTrue(DisplayOrder.copied("مرحبا\n\nsmall team photo\n\nnext", matches: "مرحبا\nsmall \u{FFFC}\nnext"))
    }

    func testCopiedTextIsQuickWithManyChips() {
        let text = "مرحبا " + String(repeating: "\u{FFFC}", count: 64) + " smal"
        let start = Date()
        XCTAssertFalse(DisplayOrder.copied("مرحبا " + String(repeating: "🎉", count: 64) + " small", matches: text))
        XCTAssertFalse(DisplayOrder.copied("مرحبا smal", matches: text + "\u{FFFC}"))
        XCTAssertTrue(DisplayOrder.copied("مرحبا smal", matches: text))
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
    }

    func testInertOutsideASelection() {
        let text = "مرحبا smal `code`"
        XCTAssertFalse(DisplayOrder.inert(outside: NSRange(location: 6, length: 4), of: text))
        XCTAssertTrue(DisplayOrder.inert(outside: NSRange(location: 6, length: 11), of: text))
        XCTAssertTrue(DisplayOrder.inert(outside: NSRange(location: 0, length: 17), of: text))
        XCTAssertFalse(DisplayOrder.inert(outside: NSRange(location: 0, length: 40), of: text))
    }

    func testDistinctWords() {
        XCTAssertTrue(DisplayOrder.distinct(["صحح", "التاني"], in: typed))
        XCTAssertFalse(DisplayOrder.distinct(["التاني"], in: typed + " التاني"))
        XCTAssertFalse(DisplayOrder.distinct(["غير"], in: typed))
        XCTAssertFalse(DisplayOrder.distinct([""], in: typed))
        // Another span with the same letters: a paste there would read the same in display order.
        XCTAssertFalse(DisplayOrder.distinct(["form"], in: "مرحبا form from"))
        XCTAssertTrue(DisplayOrder.distinct(["form"], in: "مرحبا form frame"))
        // Overlapping copies count too.
        XCTAssertFalse(DisplayOrder.distinct(["اا"], in: "ااا"))
    }

    func testHostileInputs() {
        XCTAssertFalse(DisplayOrder.reordered("", of: ""))
        XCTAssertFalse(DisplayOrder.reordered(shown, of: typed, awayFrom: NSRange(location: NSNotFound, length: 3)))
        XCTAssertTrue(DisplayOrder.reordered(shown, of: typed, awayFrom: NSRange(location: 1000, length: 3)))
    }
}
