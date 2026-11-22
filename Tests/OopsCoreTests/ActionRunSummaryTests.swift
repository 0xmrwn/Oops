import XCTest
@testable import OopsCore

final class ActionRunSummaryTests: XCTestCase {
    func testModelSummary() {
        XCTAssertEqual(ActionRunSummary.model(sameAsFix: false, name: "Haiku 5.5", effort: "low"), "Haiku 5.5 · Low")
        XCTAssertEqual(ActionRunSummary.model(sameAsFix: true, name: "Haiku 5.5", effort: "low"), "Same as Fix · Haiku 5.5 · Low")
        XCTAssertEqual(ActionRunSummary.model(sameAsFix: false, name: "qwen-4-8b", effort: nil), "qwen-4-8b")
        XCTAssertEqual(ActionRunSummary.model(sameAsFix: true, name: nil, effort: nil), "Same as Fix")
    }

    func testAgentSummary() {
        let web = ActionAgentRun(searchWeb: true, runCommands: true)
        XCTAssertEqual(ActionRunSummary.agent(model: "Sonnet 5.5", effort: "high", web), "Claude Code · Sonnet 5.5 · High · Web, commands")
        let all = ActionAgentRun(searchWeb: true, runCommands: true, usesSetup: true)
        XCTAssertTrue(ActionRunSummary.agent(model: "Sonnet 5.5", effort: "high", all).hasSuffix("Web, commands, my setup"))
        let none = ActionAgentRun(searchWeb: false, runCommands: false, usesSetup: false)
        XCTAssertEqual(ActionRunSummary.agent(model: "Sonnet 5.5", effort: "high", none), "Claude Code · Sonnet 5.5 · High")
        XCTAssertTrue(ActionRunSummary.agent(model: "Opus", effort: "xhigh", none).hasSuffix("Extra High"))
    }

    func testAgentSwitchDefaults() {
        let run = ActionAgentRun()
        XCTAssertTrue(run.searchWeb)
        XCTAssertFalse(run.runCommands)
        XCTAssertFalse(run.usesSetup)
    }
}
