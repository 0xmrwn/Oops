import XCTest
@testable import OopsCore

final class MarkerOffsetsTests: XCTestCase {
    func testGeckoPaddingAndObjectsShiftWords() {
        let readings = [
            ("hey teh @Alice Martin \u{FEFF} for shoud", "hey teh @Alice Martin\u{FEFF} for shoud", "shoud"),
            ("مرحبا تحديت عن خطة 🎉 تم نقل المراجعه", "مرحبا\nتحديت عن خطة \u{FFFC}\nتم نقل المراجعه", "المراجعه"),
            ("teh 🎉 smal 🎉 next smal", "teh \u{FFFC} smal \u{FFFC} next smal", "smal"),
            ("teh\r\n\r\nsmal", "teh\nsmal", "smal"),
        ]
        for (value, markers, word) in readings {
            let before = (value as NSString).range(of: word, options: .backwards)
            let after = (markers as NSString).range(of: word, options: .backwards)
            XCTAssertEqual(MarkerOffsets.range(before, from: value, to: markers), after)
        }
    }

    func testCapturePaddingDoesNotMakeAnEditableWordRange() {
        let value = "اترك هاذا الجزء كما هو. ثم صحح الجزء التاني @Alice Martin\n\u{FEFF}\n من الخطه"
        let markers = "اترك هاذا الجزء كما هو. ثم صحح الجزء التاني @Alice Martin\u{FEFF} من الخطه"
        XCTAssertTrue(MarkerOffsets.compatible(value, markers))
        XCTAssertNil(MarkerOffsets.range(NSRange(location: 24, length: 43), from: value, to: markers))
        XCTAssertFalse(MarkerOffsets.compatible("ab c", "a bc"))
        XCTAssertFalse(MarkerOffsets.compatible("éé a a", "e\u{301}e\u{301} a a"))
    }

    func testCanonicalUnicodeCannotChooseAnotherOccurrence() {
        let value = "éé a a", markers = "e\u{301}e\u{301} a a"
        let last = (value as NSString).range(of: "a", options: .backwards)
        XCTAssertNil(MarkerOffsets.range(last, from: value, to: markers))
    }

    func testChangedTextCannotMoveAWord() {
        for markers in ["wrong teh smal", "same the smal", "same teh @smal", "same teh s mal", "same teh smal!"] {
            let value = "same teh smal"
            XCTAssertNil(MarkerOffsets.range((value as NSString).range(of: "smal"), from: value, to: markers), markers)
        }
        XCTAssertNil(MarkerOffsets.range(NSRange(location: NSNotFound, length: 1), from: "teh", to: "teh"))
        XCTAssertNil(MarkerOffsets.range(NSRange(location: 0, length: Int.max), from: "teh", to: "teh"))
        XCTAssertNil(MarkerOffsets.range(NSRange(location: 0, length: 0), from: "teh", to: "teh"))
    }
}
