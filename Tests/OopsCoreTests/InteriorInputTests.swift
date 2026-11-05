import XCTest
@testable import OopsCore

final class InteriorInputTests: XCTestCase {
    func testArabicReplacementKeepsBothWordBoundaries() throws {
        let word = TextChange(location: 40, original: "واصبحت", replacement: "وأصبحت")
        let inner = try XCTUnwrap(TextEdits.interior(of: word))
        XCTAssertEqual(inner, TextChange(location: 41, original: "ا", replacement: "أ"))
        XCTAssertEqual((word.original as NSString).replacingCharacters(in: NSRange(location: 1, length: 1), with: inner.replacement), word.replacement)
    }

    func testOffsetsAndTrimmingKeepWholeGraphemes() {
        let word = TextChange(location: 9, original: "🧪cafeine", replacement: "🧪caféine")
        XCTAssertEqual(TextEdits.interior(of: word), TextChange(location: 14, original: "e", replacement: "é"))
        let decomposed = TextChange(location: 9, original: "🧪cafe\u{301}ine", replacement: "🧪caffine")
        XCTAssertEqual(TextEdits.interior(of: decomposed), TextChange(location: 14, original: "e\u{301}", replacement: "f"))
    }

    func testCanonicalEqualityDoesNotTrimDifferentUTF16() {
        XCTAssertNil(TextEdits.interior(of: TextChange(location: 0, original: "éxword", replacement: "e\u{301}yword")))
    }

    func testBoundaryChangesAndEmptySelectionsKeepWholeWord() {
        for (before, after) in [("teh", "the"), ("caat", "cat"), ("cat", "caat"), ("cat", "cat")] {
            XCTAssertNil(TextEdits.interior(of: TextChange(location: 0, original: before, replacement: after)))
        }
    }

    func testInteriorProofCannotBorrowWholeWordUniqueness() throws {
        let draft = "ا واصبحت", next = "ا وأصبحت", misplaced = "أ واصبحت"
        let word = TextChange(location: 2, original: "واصبحت", replacement: "وأصبحت")
        let inner = try XCTUnwrap(TextEdits.interior(of: word))
        XCTAssertTrue(DisplayOrder.distinct([word.original], in: draft))
        XCTAssertFalse(DisplayOrder.distinct([inner.original], in: draft))
        XCTAssertFalse(DisplayOrder.confirms(misplaced, next: next, draft: draft, pasted: word.range,
                                             distinct: DisplayOrder.distinct([inner.original], in: draft)))
    }

    func testInvalidOffsetCannotOverflow() {
        XCTAssertNil(TextEdits.interior(of: TextChange(location: Int.max, original: "wrod", replacement: "word")))
    }
}
