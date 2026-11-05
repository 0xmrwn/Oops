import XCTest
@testable import OopsCore

/// Fix text pressed again on a draft Oops just corrected (D10): restore, re-apply or correct.
final class CorrectionToggleTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private var corrected: CorrectionToggle { CorrectionToggle(original: "ths is a smal test", applied: "this is a small test", date: start) }
    private var restored: CorrectionToggle { corrected.toggled(at: start) }

    func testUnchangedCorrectionRestores() {
        XCTAssertEqual(corrected.press(holding: "this is a small test", sameField: true, at: start + 10), .restore)
    }

    func testUnchangedOriginalAfterRestoreReapplies() {
        XCTAssertEqual(restored.press(holding: "ths is a smal test", sameField: true, at: start + 10), .reapply)
    }

    func testReapplyingTogglesBackToRestore() {
        let reapplied = restored.toggled(at: start + 60)
        XCTAssertEqual(reapplied.state, .corrected)
        XCTAssertEqual(reapplied.press(holding: "this is a small test", sameField: true, at: start + 61), .restore)
    }

    func testTypedSinceCorrects() {
        XCTAssertEqual(corrected.press(holding: "this is a small test!", sameField: true, at: start + 10), .correct)
        XCTAssertEqual(restored.press(holding: "ths is a smal test ok", sameField: true, at: start + 10), .correct)
    }

    func testWhitespaceOnlyDifferencesCountAsChanged() {
        for text in ["this is a small test ", " this is a small test", "this is a small test\n", "this  is a small test", "this is a\nsmall test"] {
            XCTAssertEqual(corrected.press(holding: text, sameField: true, at: start + 10), .correct, text.debugDescription)
        }
        XCTAssertEqual(restored.press(holding: "ths is a smal test ", sameField: true, at: start + 10), .correct)
    }

    func testSpaceReadBackAsNonBreakingIsTheSameDraft() {
        XCTAssertEqual(corrected.press(holding: "this is a\u{A0}small test", sameField: true, at: start + 10), .restore)
    }

    func testAnotherFieldCorrects() {
        XCTAssertEqual(corrected.press(holding: "this is a small test", sameField: false, at: start + 10), .correct)
        XCTAssertEqual(restored.press(holding: "ths is a smal test", sameField: false, at: start + 10), .correct)
    }

    func testOtherTextInTheSameStateCorrects() {
        // A corrected draft undone in the host (⌘Z) isn't a restore Oops made: it is corrected again.
        XCTAssertEqual(corrected.press(holding: "ths is a smal test", sameField: true, at: start + 10), .correct)
        XCTAssertEqual(restored.press(holding: "this is a small test", sameField: true, at: start + 10), .correct)
    }

    func testFiveMinutesIsTheBoundary() {
        XCTAssertEqual(corrected.press(holding: "this is a small test", sameField: true, at: start + 299.9), .restore)
        XCTAssertEqual(corrected.press(holding: "this is a small test", sameField: true, at: start + 300), .correct)
        XCTAssertEqual(restored.press(holding: "ths is a smal test", sameField: true, at: start + 300), .correct)
    }

    func testToggleRestartsTheFiveMinutes() {
        let later = corrected.toggled(at: start + 250)
        XCTAssertEqual(later.press(holding: "ths is a smal test", sameField: true, at: start + 500), .reapply)
        XCTAssertEqual(later.press(holding: "ths is a smal test", sameField: true, at: start + 550), .correct)
    }

    func testClockMovedBackCorrects() {
        XCTAssertEqual(corrected.press(holding: "this is a small test", sameField: true, at: start - 1), .correct)
    }

    func testCanRestoreOnlyAFreshCorrection() {
        XCTAssertTrue(corrected.canRestore(at: start + 10))
        XCTAssertFalse(corrected.canRestore(at: start + 300))
        XCTAssertFalse(restored.canRestore(at: start + 10))
    }

    func testARemountInTheSameSlotIsTheSameField() {
        let composer = CGRect(x: 100, y: 600, width: 500, height: 60)
        XCTAssertTrue(CorrectionToggle.sameSlot(composer, composer))
        // Grown by a line with the fix, its bottom edge where it was.
        XCTAssertTrue(CorrectionToggle.sameSlot(CGRect(x: 100, y: 580, width: 500, height: 80), composer))
    }

    func testAnotherFieldBesideItIsNot() {
        let full = CGRect(x: 0, y: 0, width: 1100, height: 754)
        // The lower half of the same window: same width and bottom edge, half the height.
        XCTAssertFalse(CorrectionToggle.sameSlot(CGRect(x: 0, y: 380, width: 1100, height: 374), full))
        XCTAssertFalse(CorrectionToggle.sameSlot(CGRect(x: 0, y: 0, width: 540, height: 754), full))
        XCTAssertFalse(CorrectionToggle.sameSlot(CGRect(x: 0, y: 200, width: 1100, height: 754), full))
    }
}
