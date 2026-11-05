import XCTest
@testable import OopsCore

final class TextOffsetObservationTests: XCTestCase {
    func testObservedAttachmentDriftBeyondTheOrdinaryWindow() {
        let value = "Hi team,\n\nQuick update on teh planning \u{FEFF} \u{FEFF} for next week.\n\nThe review moved to thursday, plese have your slides ready."
        XCTAssertNil(TextOffsets.nearest("o thu", in: value, to: 89, within: 8))
        XCTAssertEqual(TextOffsets.uniqueOccurrence("o thu", in: value, to: 89, within: 32), 77)
    }

    func testLargerWindowCannotChooseAnotherRepeatedFragment() {
        XCTAssertNil(TextOffsets.uniqueOccurrence("same", in: "same x same", to: 7, within: 32))
        XCTAssertNil(TextOffsets.uniqueOccurrence("aaa", in: "aaaa", to: 0, within: 32))
        XCTAssertNil(TextOffsets.uniqueOccurrence("word", in: "word", to: 40, within: 32))
        XCTAssertNil(TextOffsets.uniqueOccurrence("", in: "word", to: 0, within: 32))
        XCTAssertNil(TextOffsets.uniqueOccurrence("é", in: "e\u{301}", to: 0, within: 32))
        XCTAssertEqual(TextOffsets.uniqueOccurrence("word", in: "🎉 word", to: 3, within: 32), 3)
    }
}
