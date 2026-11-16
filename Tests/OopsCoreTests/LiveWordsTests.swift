@testable import OopsCore
import XCTest

final class LiveWordsTests: XCTestCase {
    func testTextJoinsBothPartsOnOneLine() {
        XCTAssertEqual(LiveWords(stable: " The quick\nbrown", changing: " fox  jumps ").text, "The quick brown fox jumps")
        XCTAssertEqual(LiveWords(stable: "", changing: " fox").text, "fox")
    }

    func testWhitespaceOnlyWordsAreEmpty() {
        XCTAssertTrue(LiveWords(stable: " \n", changing: "\t ").isEmpty)
        XCTAssertTrue(LiveWords(stable: "").isEmpty)
        XCTAssertFalse(LiveWords(stable: "", changing: "a").isEmpty)
    }
}
