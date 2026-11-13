import XCTest
@testable import OopsCore

final class InsertionTests: XCTestCase {
    func testInsertFollowsTheApplicationPolicy() {
        func verdict(_ bundleID: String?, turnedOff: Set<String> = []) -> EditorApplicationPolicy.Verdict {
            EditorApplicationPolicy.verdict(bundleID: bundleID, bundleURL: nil, foregroundBundleID: bundleID, foregroundBundleURL: nil,
                                            turnedOff: turnedOff)
        }
        XCTAssertNil(TextInsertion.refusal(for: verdict("com.apple.TextEdit")))
        XCTAssertEqual(TextInsertion.refusal(for: verdict("com.apple.Terminal")), .appDenied)
        XCTAssertEqual(TextInsertion.refusal(for: verdict("com.1password.1password")), .appDenied)
        XCTAssertEqual(TextInsertion.refusal(for: verdict("com.apple.TextEdit", turnedOff: ["com.apple.TextEdit"])), .appTurnedOff)
        XCTAssertEqual(TextInsertion.refusal(for: verdict(nil)), .noEditor)
    }

    func testASecureFieldHoldsASecretWhateverItSays() {
        XCTAssertTrue(TextInsertion.holdsSecret(role: "AXTextField", subrole: "AXSecureTextField", descriptions: [], value: nil, readable: true))
        XCTAssertTrue(TextInsertion.holdsSecret(role: "AXGroup", subrole: "AXSecureTextField", descriptions: [], value: nil, readable: false))
    }

    func testAFieldLabelledAsPasswordOrCodeHoldsASecret() {
        XCTAssertTrue(TextInsertion.holdsSecret(role: "AXTextField", subrole: nil, descriptions: ["Password"], value: "", readable: true))
        XCTAssertTrue(TextInsertion.holdsSecret(role: "AXTextField", subrole: nil, descriptions: ["one-time-code"], value: "", readable: true))
        // A message composer is a text area: its label never makes it a secret.
        XCTAssertFalse(TextInsertion.holdsSecret(role: "AXTextArea", subrole: nil, descriptions: ["Password hint"], value: "", readable: true))
        // An editor that exposes no text has only its labels to go by.
        XCTAssertTrue(TextInsertion.holdsSecret(role: "AXTextArea", subrole: nil, descriptions: ["API key"], value: nil, readable: false))
        XCTAssertFalse(TextInsertion.holdsSecret(role: "AXGroup", subrole: nil, descriptions: ["Message"], value: nil, readable: false))
    }

    func testAFieldShowingOnlyMaskCharactersHoldsASecret() {
        XCTAssertTrue(TextInsertion.holdsSecret(role: "AXTextField", subrole: nil, descriptions: [], value: "••••••", readable: true))
        XCTAssertFalse(TextInsertion.holdsSecret(role: "AXTextArea", subrole: nil, descriptions: [], value: "••••••", readable: true))
        XCTAssertFalse(TextInsertion.holdsSecret(role: "AXTextField", subrole: nil, descriptions: ["Search"], value: "", readable: true))
    }

    func testInsertIntoAnEmptyField() {
        XCTAssertEqual(TextInsertion.result(of: "hello", in: "", replacing: NSRange(location: 0, length: 0)), "hello")
    }

    func testInsertIntoAFieldThatReadsOnlyItsPlaceholder() {
        XCTAssertEqual(TextInsertion.result(of: "hello", in: "Type a message", replacing: NSRange(location: 14, length: 0),
                                            placeholders: ["Type a message"]), "hello")
        // The same words typed by the person are text: the insert goes at the caret.
        XCTAssertEqual(TextInsertion.result(of: " now", in: "Type a message", replacing: NSRange(location: 14, length: 0)), "Type a message now")
    }

    func testInsertAtACaretMidText() {
        XCTAssertEqual(TextInsertion.result(of: "release ", in: "send the notes today", replacing: NSRange(location: 9, length: 0)),
                       "send the release notes today")
    }

    func testInsertOverASelection() {
        XCTAssertEqual(TextInsertion.result(of: "minutes", in: "send the notes today", replacing: NSRange(location: 9, length: 5)),
                       "send the minutes today")
    }

    func testInsertCountsInUTF16UnitsLikeTheEditorsRanges() {
        XCTAssertEqual(TextInsertion.result(of: "à demain", in: "Merci 🙏 ", replacing: NSRange(location: 9, length: 0)), "Merci 🙏 à demain")
        XCTAssertEqual(TextInsertion.result(of: "👍", in: "ok 🙏", replacing: NSRange(location: 3, length: 2)), "ok 👍")
    }

    func testASelectionOutsideTheTextGivesNothingToConfirm() {
        XCTAssertNil(TextInsertion.result(of: "x", in: "abc", replacing: NSRange(location: 2, length: 5)))
        XCTAssertNil(TextInsertion.result(of: "x", in: "abc", replacing: NSRange(location: NSNotFound, length: 0)))
    }
}
