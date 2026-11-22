import XCTest
@testable import OopsCore

final class SkillCompletionTests: XCTestCase {
    private func completion(_ text: String, caret: Int? = nil) -> SkillCompletion? {
        ClaudeSkills.completion(in: text, caret: caret ?? (text as NSString).length)
    }

    func testCompletionAtTheEnd() {
        let found = completion("Use $re")
        XCTAssertEqual(found?.partial, "re")
        XCTAssertEqual(found?.sigil, "$")
        XCTAssertEqual(found?.range, NSRange(location: 4, length: 3))
        XCTAssertEqual(completion("/")?.partial, "")
        XCTAssertEqual(completion("start /rev")?.range, NSRange(location: 6, length: 4))
    }

    func testCompletionMidText() {
        let text = "Use $re and more"
        let found = completion(text, caret: 7)
        XCTAssertEqual(found?.partial, "re")
        XCTAssertEqual(found?.range, NSRange(location: 4, length: 3))
        XCTAssertNil(completion(text, caret: 6))
        XCTAssertEqual(completion("(\"$re", caret: 5)?.partial, "re")
        XCTAssertEqual(completion("Use $", caret: 5)?.partial, "")
    }

    func testNoCompletionOutsideAWordStart() {
        for text in ["a$re", "path/re", "https://x/re", "//re", "Use $re ", "Use $re x", "$-re", "Use $_re", "plain", ""] {
            XCTAssertNil(completion(text), text)
        }
        XCTAssertNil(completion("Use $review", caret: 7))
        XCTAssertNil(completion("Use $re", caret: 99))
        XCTAssertNil(completion("Use $re", caret: -1))
    }

    func testTheAttachmentCharacterIsNeverInAMention() {
        let mark = "\u{FFFC}"
        XCTAssertNil(completion("\(mark)$re"))
        XCTAssertEqual(completion("$re\(mark)", caret: 3)?.partial, "re")
        XCTAssertEqual(ClaudeSkills.tokenRanges(in: "\(mark)/review /review\(mark) /review \(mark)", known: ["review"]),
                       [NSRange(location: 18, length: 7)])
    }

    func testReplacementKeepsTheSigil() {
        XCTAssertEqual(completion("Use $re")?.replacement(for: "review"), "$review ")
        XCTAssertEqual(completion("/re")?.replacement(for: "Review"), "/Review ")
    }

    func testAnExactNameInAnyCaseHasNothingLeftToOffer() throws {
        let typed = try XCTUnwrap(completion("Use $Review"))
        XCTAssertTrue(typed.isTyped(in: ["review"]))
        XCTAssertFalse(typed.isTyped(in: ["review", "reviewer"]))
        XCTAssertFalse(try XCTUnwrap(completion("Use $rev")).isTyped(in: ["review"]))
    }

    func testSuggestionsOrderAndLimit() {
        let names = ["summarize", "review", "Research", "code-review", "pre-review", "rewrite"]
        XCTAssertEqual(ClaudeSkills.suggestions("re", from: names), ["Research", "review", "rewrite", "code-review", "pre-review"])
        XCTAssertEqual(ClaudeSkills.suggestions("", from: names, limit: 3), ["code-review", "pre-review", "Research"])
        XCTAssertEqual(ClaudeSkills.suggestions("RE", from: names, limit: 2), ["Research", "review"])
        XCTAssertEqual(ClaudeSkills.suggestions("zzz", from: names), [])
    }

    func testTokenRanges() {
        let text = "Run /review, then $Review and /reviewer, $other, a/review"
        let ranges = ClaudeSkills.tokenRanges(in: text, known: ["review"])
        XCTAssertEqual(ranges.map { (text as NSString).substring(with: $0) }, ["/review", "$Review"])
        XCTAssertEqual(ClaudeSkills.tokenRanges(in: text, known: []), [])
        // Ranges count UTF-16 units: the emoji before the mention is two of them.
        let wide = "😀 $review"
        XCTAssertEqual(ClaudeSkills.tokenRanges(in: wide, known: ["review"]), [NSRange(location: 3, length: 7)])
    }
}
