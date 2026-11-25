import XCTest
@testable import OopsCore

final class ActionRunSummaryTests: XCTestCase {
    private func model(fix: Bool = false, _ name: String?, _ effort: String?) -> ActionRunSummary {
        .model(sameAsFix: fix, providerID: "claude-code", name: name, effort: effort)
    }

    private func agent(web: Bool = false, commands: Bool = false, setup: Bool = false, problem: String? = nil) -> ActionRunSummary {
        .agent(model: "Sonnet 5.5", effort: "xhigh", .init(searchWeb: web, runCommands: commands, usesSetup: setup), problem: problem)
    }

    func testSameAsFix() {
        let fix = model(fix: true, "Haiku 5.5", "low")
        XCTAssertEqual(fix.text, "Same as Fix · Haiku 5.5 · Low")
        XCTAssertEqual(fix.spoken, "Haiku 5.5, Low, same as Fix")
        XCTAssertEqual(model(fix: true, nil, nil).text, "Same as Fix")
        XCTAssertEqual(model(fix: true, nil, nil).spoken, "Same as Fix")
    }

    func testModelWithLevel() {
        let chosen = model("GPT-6.1 Sol", "high")
        XCTAssertEqual(chosen.level, "High")
        XCTAssertEqual(chosen.text, "GPT-6.1 Sol · High")
        XCTAssertEqual(chosen.spoken, "GPT-6.1 Sol, High")
        XCTAssertFalse(chosen.agent)
        XCTAssertTrue(chosen.permissions.isEmpty)
    }

    func testModelWithoutLevels() {
        XCTAssertEqual(model("qwen-4-8b", nil).text, "qwen-4-8b")
        XCTAssertEqual(model("qwen-4-8b", nil).spoken, "qwen-4-8b")
    }

    func testAgentWithoutPermissions() {
        let none = agent()
        XCTAssertTrue(none.agent)
        XCTAssertTrue(none.permissions.isEmpty)
        XCTAssertEqual(none.text, "Claude Code · Sonnet 5.5 · Extra High")
        XCTAssertEqual(none.spoken, "Sonnet 5.5, Extra High, with Claude Code; no tools")
    }

    func testAgentPermissions() {
        XCTAssertEqual(agent(web: true).permissions, [.web])
        XCTAssertEqual(agent(web: true).text, "Claude Code · Sonnet 5.5 · Extra High · Web")
        XCTAssertEqual(agent(web: true).spoken, "Sonnet 5.5, Extra High, with Claude Code; can search the web")
        let two = agent(web: true, setup: true)
        XCTAssertEqual(two.permissions.map(\.label), ["Web", "My setup"])
        XCTAssertEqual(two.text, "Claude Code · Sonnet 5.5 · Extra High · Web, my setup")
        XCTAssertEqual(two.spoken, "Sonnet 5.5, Extra High, with Claude Code; can search the web and use your setup")
        let all = agent(web: true, commands: true, setup: true)
        XCTAssertEqual(all.permissions, [.web, .commands, .setup])
        XCTAssertEqual(all.text, "Claude Code · Sonnet 5.5 · Extra High · Web, commands, my setup")
        XCTAssertEqual(all.spoken, "Sonnet 5.5, Extra High, with Claude Code; can search the web, run commands and use your setup")
    }

    func testAgentUnavailable() {
        let signedOut = agent(web: true, setup: true, problem: "Signed out")
        XCTAssertEqual(signedOut.text, "Claude Code · Signed out · Sonnet 5.5 · Extra High · Web, my setup")
        XCTAssertEqual(signedOut.spoken, "Claude Code is signed out; Sonnet 5.5, Extra High, with Claude Code; can search the web and use your setup")
        XCTAssertTrue(agent(problem: "Not installed").spoken.hasPrefix("Claude Code is not installed; "))
        XCTAssertTrue(agent(problem: "Can’t connect").spoken.hasPrefix("Claude Code can’t connect; "))
    }

    func testAgentSwitchDefaults() {
        let run = ActionAgentRun()
        XCTAssertTrue(run.searchWeb)
        XCTAssertFalse(run.runCommands)
        XCTAssertFalse(run.usesSetup)
    }
}
