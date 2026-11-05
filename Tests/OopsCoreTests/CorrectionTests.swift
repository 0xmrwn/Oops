import XCTest
@testable import OopsCore

/// Transactions: the draft, selection and replacement checks around a correction.
final class CorrectionTests: XCTestCase {
    func testPartialSelectionCannotRewriteItsEnclosingProtectedSpan() throws {
        for value in ["hello @writr", "check `writr`", "see https://example.com/writr", "open /tmp/writr"] {
            let selection = (value as NSString).range(of: "writr")
            let transaction = try TextTransaction(value: value, selection: selection, selectedText: "writr")
            // The adapter sees no enclosing syntax. Only the transaction has
            // enough context to stop this otherwise-valid structured response.
            let decoded = try CorrectionPolicy.decode(#"{"text":"writer"}"#, original: transaction.source)
            XCTAssertThrowsError(try transaction.validatedReplacement(decoded), value)
            XCTAssertEqual(try transaction.validatedReplacement("writr"), value)
        }
    }
    func testSelectedProseAroundProtectedSpanCanStillBeCorrected() throws {
        let value = "👋 ths is `literal` for @alice"
        let selection = (value as NSString).range(of: "ths is `literal`")
        let transaction = try TextTransaction(value: value, selection: selection)
        XCTAssertEqual(try transaction.validatedReplacement("this is `literal`"), "👋 this is `literal` for @alice")
        XCTAssertThrowsError(try transaction.validatedReplacement("this is `other`"))
    }
    func testUTF16SelectionAndReplacement() throws {
        let value = "👨‍👩‍👧‍👦 café ths test 😊"
        let range = (value as NSString).range(of: "ths")
        let t = try TextTransaction(value: value, selection: range, selectedText: "ths")
        XCTAssertEqual(t.source, "ths")
        XCTAssertEqual(t.replacement("this"), "👨‍👩‍👧‍👦 café this test 😊")
        XCTAssertEqual(t.caret(after: "this").location, range.location + 4)
    }
    func testSelectionOutsideTextAndSurrogateSplitAreRejected() {
        XCTAssertThrowsError(try TextTransaction(value: "a", selection: NSRange(location: 5, length: 0)))
        XCTAssertThrowsError(try TextTransaction(value: "😊", selection: NSRange(location: 1, length: 1)))
        XCTAssertThrowsError(try TextTransaction(value: "hello", selection: NSRange(location: 0, length: 2), selectedText: "wrong"))
    }
    func testFullDraftAndGuards() throws {
        let t = try TextTransaction(value: "bonjor\nhello", selection: NSRange(location: 3, length: 0))
        XCTAssertEqual(t.source, "bonjor\nhello")
        XCTAssertTrue(t.canApply(value: t.before, selection: t.selection))
        XCTAssertFalse(t.canApply(value: t.before + "!", selection: t.selection))
        XCTAssertFalse(t.canApply(value: t.before, selection: NSRange(location: 0, length: 0)))
    }
    func testAttachmentsAreKeptInPlace() throws {
        let t = try TextTransaction(value: "teh \u{FFFC} smal", selection: NSRange(location: 0, length: 0))
        XCTAssertNoThrow(try CorrectionPolicy.validate("the \u{FFFC} small", original: t.source))
        XCTAssertThrowsError(try CorrectionPolicy.validate("the small", original: t.source))
        XCTAssertThrowsError(try CorrectionPolicy.validate("the \u{FFFC}\u{FFFC} small", original: t.source))
    }
    func testCanonicalEquivalenceDoesNotBypassUTF16StaleGuard() throws {
        let original = "é ths", changed = "e\u{301} ths"
        XCTAssertEqual(original, changed) // Swift semantic equality is intentionally insufficient here.
        let t = try TextTransaction(value: original, selection: NSRange(location: 0, length: 0))
        XCTAssertFalse(t.canApply(value: changed, selection: t.selection))
        XCTAssertFalse(sameText(original, changed))
    }
    func testSmallSelectionWithinLongDraftRemainsReversible() throws {
        let original = String(repeating: "x", count: 17_000) + " ths"
        let selection = NSRange(location: 17_001, length: 3)
        let t = try TextTransaction(value: original, selection: selection)
        XCTAssertEqual(try t.validatedReplacement("this"), String(repeating: "x", count: 17_000) + " this")
        let inverse = try TextTransaction(value: t.replacement("this"), selection: NSRange(location: selection.location, length: 4), selectedText: "this", maximumSourceLength: 32_000)
        XCTAssertTrue(sameText(inverse.replacement(t.source), original))
    }
}
