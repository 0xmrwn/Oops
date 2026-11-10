import Foundation
@testable import OopsCore
import XCTest

final class FormatCarryTests: XCTestCase {
    /// The original text each replacement character takes its formatting from, as one string.
    private func carried(_ original: String, _ replacement: String) -> String {
        let source = original as NSString
        return FormatCarry.sources(original: original, replacement: replacement).map { run in
            String(repeating: source.substring(with: source.rangeOfComposedCharacterSequence(at: run.source)), count: run.range.length)
        }.joined()
    }

    func testUnchangedWordsKeepTheirOwnFormatting() {
        // "handy" keeps its own (bold) characters; the added comma takes the space's, not the y's.
        XCTAssertEqual(carried("handy i", "handy, I"), "handy  i")
        XCTAssertEqual(carried("handy, evriday,", "handy every day."), "handy,, evriday,")
    }

    func testAFixInsideAWordTakesThatWordsFormatting() {
        XCTAssertEqual(carried("hnady", "handy"), "hnady")
        // An inserted letter sits beside a letter.
        XCTAssertEqual(carried("smal", "small"), "small")
        XCTAssertEqual(carried("vry", "very"), "vvry")
    }

    func testRunsCoverTheReplacementInUTF16() {
        let runs = FormatCarry.sources(original: "café 👍 teh", replacement: "café 👍 the")
        XCTAssertEqual(runs.first?.range.location, 0)
        XCTAssertEqual(runs.reduce(0) { $0 + $1.range.length }, ("café 👍 the" as NSString).length)
        for (first, second) in zip(runs, runs.dropFirst()) { XCTAssertEqual(NSMaxRange(first.range), second.range.location) }
        XCTAssertTrue(FormatCarry.sources(original: "", replacement: "x").isEmpty)
    }

    func testEditsLeaveOutUntouchedWordsAtTheirEnds() {
        func inner(_ original: String, _ replacement: String) -> TextChange? {
            TextEdits.besideWords(of: TextChange(location: 10, original: original, replacement: replacement))
        }
        XCTAssertEqual(inner("handy, evriday,", "handy every day."), TextChange(location: 15, original: ", evriday,", replacement: " every day."))
        XCTAssertEqual(inner("handy i", "handy, I"), TextChange(location: 15, original: " i", replacement: ", I"))
        XCTAssertEqual(inner("i, handy", "I handy"), TextChange(location: 10, original: "i, ", replacement: "I "))
        // Inside a word, or with nothing left on one side, the whole span stays.
        XCTAssertNil(inner("hnady", "handy"))
        XCTAssertNil(inner("teh", "the"))
        XCTAssertNil(inner("handy", "handy,"))
        XCTAssertNil(inner("handy,", "handy"))
    }
}
