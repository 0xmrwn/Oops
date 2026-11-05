import XCTest
@testable import OopsCore

/// Whatever an app reports through Accessibility, nothing traps: offsets that are negative, past the
/// end, NSNotFound, or whose location plus length overflows.
final class HostileOffsetsTests: XCTestCase {
    func testImplausibleRangesAreRejected() {
        XCTAssertEqual(TextOffsets.plausible(location: 3, length: 4), NSRange(location: 3, length: 4))
        for (location, length) in [(-1, 0), (0, -1), (NSNotFound, 0), (0, Int.max), (Int.max, Int.max), (Int.max - 1, 2),
                                   (TextOffsets.limit, 1), (Int.min, 5)] {
            XCTAssertNil(TextOffsets.plausible(location: location, length: length), "\(location),\(length)")
        }
        XCTAssertEqual(TextOffsets.between(12, 15, from: 10), NSRange(location: 2, length: 3))
        for (lower, upper, base) in [(5, 3, 0), (3, 5, 4), (NSNotFound, NSNotFound, 0), (0, Int.max, 0), (Int.max, Int.max, Int.max), (0, 1, -1)] {
            XCTAssertNil(TextOffsets.between(lower, upper, from: base), "\(lower),\(upper),\(base)")
        }
    }

    func testTransactionsRejectHostileSelections() {
        for selection in [NSRange(location: NSNotFound, length: 0), NSRange(location: 0, length: Int.max), NSRange(location: 99, length: 1),
                          NSRange(location: -1, length: 1), NSRange(location: Int.max, length: Int.max)] {
            XCTAssertThrowsError(try TextTransaction(value: "teh docs", selection: selection))
        }
        XCTAssertThrowsError(try TextTransaction(value: "", selection: NSRange(location: 0, length: 0)))
    }

    func testTextChecksTakeEmptyAndMismatchedStrings() {
        XCTAssertTrue(TextEdits.between("", "").isEmpty)
        XCTAssertEqual(CorrectionPolicy.applying(TextEdits.between("", "a"), to: ""), "a")
        XCTAssertEqual(CorrectionPolicy.applying(TextEdits.between("a", ""), to: "a"), "")
        XCTAssertFalse(TextEdits.misplaced("", in: "", over: ""))
        XCTAssertFalse(TextEdits.misplaced("long paste", in: "x", over: ""))
        XCTAssertNil(TextEdits.atomSpelling(value: "", markers: ""))
        XCTAssertNil(TextEdits.atomSpelling(value: "", markers: "\u{FFFC}\u{FFFC}x"))
        XCTAssertNil(TextEdits.atomSpelling(value: "", markers: "\u{FFFC}"))
        XCTAssertFalse(TextEdits.changedBeside(NSRange(location: NSNotFound, length: 0), current: "", expected: ""))
        XCTAssertTrue(TextEdits.changedBeside(NSRange(location: 50, length: 3), current: "ab", expected: "abc"))
        XCTAssertEqual(TextEdits.undo("", before: "", misplaced: "x"), .restored)
    }

    func testASelectionThatCameOutOffIsFound() {
        let text = "fix teh second \u{FFFC} part, it is a smal change"
        let smal = (text as NSString).range(of: "smal").location
        XCTAssertEqual(TextOffsets.nearest("smal", in: text, to: smal - 1, within: 8), smal)
        XCTAssertNil(TextOffsets.nearest("smal", in: text, to: 0, within: 8))
        XCTAssertNil(TextOffsets.nearest("", in: text, to: 3, within: 8))
        XCTAssertNil(TextOffsets.nearest("longer than the text itself, by far, surely", in: "short", to: 0, within: 8))
        XCTAssertNil(TextOffsets.nearest("a", in: "a", to: Int.max - 1, within: 8))
        XCTAssertEqual(TextOffsets.nearest("a", in: "a", to: 0, within: 0), 0)
    }

    func testADraftReportedWithOtherSpacesIsTheSameDraft() {
        XCTAssertTrue(sameDraft("fix teh part", "fix\u{00A0}teh part"))
        XCTAssertFalse(sameDraft("fix teh part", "fix the part"))
        XCTAssertFalse(sameDraft("fix teh", "fix teh "))
        XCTAssertTrue(sameDraft("", ""))
        let t = try? TextTransaction(value: "a b", selection: NSRange(location: 3, length: 0))
        XCTAssertEqual(t?.canApply(value: "a\u{00A0}b", selection: NSRange(location: 3, length: 0)), true)
    }
}
