import XCTest
@testable import OopsCore

final class ClaudeSkillsTests: XCTestCase {
    func testRewrite() {
        for (source, expected) in [
            ("$review", "/review"), ("Please $review then $review.", "Please /review then /review."),
            ("/Review $unknown /unknown", "/review $unknown /unknown"), ("$Review. ($review)", "/review. (/review)"),
            ("a$review path/review </review> https://x/review /usr/bin/x", "a$review path/review </review> https://x/review /usr/bin/x"),
            ("“$mixed-skill” '$MIXED-SKILL'", "“/Mixed-Skill” '/Mixed-Skill'"),
        ] {
            XCTAssertEqual(ClaudeSkills.rewrite(source, known: ["review", "Mixed-Skill"]), expected)
        }
    }

    func testMentionRanges() {
        let text = "é $review, /later"
        let mentions = ClaudeSkills.mentions(in: text)
        XCTAssertEqual(mentions.map { String(text[$0.range]) }, ["$review", "/later"])
        XCTAssertEqual(mentions.map(\.sigil), ["$", "/"])
    }

    func testCatalogExcludesBuiltins() {
        let object = ClaudeProcess.object(Data(#"{"type":"control_response","response":{"response":{"commands":[{"name":"clear","builtin":true},{"name":"review"},{"name":"other","builtin":false}]}}}"#.utf8))
        XCTAssertEqual(ClaudeSkills.decodeNames(object), ["review", "other"])
    }
}
