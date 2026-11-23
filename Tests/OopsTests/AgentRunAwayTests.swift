import ApplicationServices
import Foundation
@testable import Oops
import OopsCore
import SwiftUI
import Testing

/// An agent run while the person is elsewhere: when its drop gives way, when it parks, what Return and Escape do with
/// the ready drop at the caret, and what a changed draft does. Fix holds the drop throughout, so no drop is shown.
@MainActor struct AgentRunAwayTests {
    @Test func `a run away from its field gives its drop to any feature`() {
        let agent = Self.agent()
        agent.handle(.started)
        #expect(agent.drop.busy() && !agent.drop.away())
        agent.handle(.focus(false))
        #expect(!agent.drop.busy() && agent.drop.away(), "leaving, before it parks")
        agent.handle(.parkDue)
        #expect(!agent.drop.busy() && agent.drop.away())
        agent.handle(.focus(true))
        #expect(agent.drop.busy() && !agent.drop.away())
    }

    @Test func `the drop parks once the person has stayed away`() async throws {
        let agent = Self.agent()
        agent.handle(.started); agent.handle(.focus(false))
        #expect(agent.flow.place == .caret)
        let left = ContinuousClock.now
        while agent.flow.place == .caret, left.duration(to: .now) < .seconds(10) { try await Task.sleep(for: .milliseconds(50)) }
        #expect(agent.flow.place == .parked)
        #expect(left.duration(to: .now) >= AgentRunFlow.parkDelay, "not before the delay")
    }

    @Test func `a quick trip away and back leaves the drop at the caret`() async throws {
        let agent = Self.agent()
        agent.handle(.started); agent.handle(.focus(false)); agent.handle(.focus(true))
        try await Task.sleep(for: AgentRunFlow.parkDelay + .milliseconds(300))
        #expect(agent.flow.place == .caret && agent.flow.holdsDrop)
    }

    @Test func `Return with the draft as read puts the answer in`() async throws {
        var passed = 0
        let agent = try Self.readyHere(unchanged: true) { passed += 1 }
        agent.confirmed()
        for _ in 0 ..< 200 where agent.flow.phase != .idle { await Task.yield() }
        #expect(agent.flow.phase == .idle)
        #expect(passed == 0, "Return was the drop's")
    }

    @Test func `Return after the draft changed goes on to the field and offers the answer to copy`() async throws {
        var passed = 0
        let agent = try Self.readyHere(unchanged: false) { passed += 1 }
        let waiting = Task { await agent.readyOutcome() }
        agent.confirmed()
        #expect(await waiting.value == .held)
        #expect(passed == 1)
        #expect(agent.copyable == "answer" && agent.held == nil)
        #expect(agent.flow.phase == .idle)
    }

    @Test func `Return with no ready drop at the caret goes on to the field`() {
        var passed = 0
        let agent = Self.agent()
        agent.passReturn = { passed += 1 }
        agent.confirmed()
        #expect(passed == 1)
    }

    @Test func `Escape at the caret parks the ready drop rather than cancelling anything`() throws {
        let agent = try Self.readyHere(unchanged: true) {}
        agent.escaped()
        #expect(agent.isReady && agent.flow.place == .parked)
        #expect(agent.held == "answer")
    }

    @Test func `a draft changed under the ready drop offers the answer to copy`() async throws {
        let agent = try Self.readyHere(unchanged: true) {}
        let waiting = Task { await agent.readyOutcome() }
        for _ in 0 ..< 10 { await Task.yield() }
        agent.handle(.edited)
        #expect(await waiting.value == .held)
        #expect(agent.copyable == "answer")
    }

    @Test func `the watch tells when the app in front goes full screen, only while asked to`() async throws {
        let front = try #require(NSWorkspace.shared.frontmostApplication?.processIdentifier)
        var told: [Bool] = []
        let watch = AgentFocusWatch(holds: { _ in false }, fullScreen: { $0 == front })
        watch.screenChanged = { told.append($0) }
        watch.start(try Self.snapshot("draft"))
        for _ in 0 ..< 20 { await Task.yield() }
        #expect(told.isEmpty)
        watch.watchesScreen = true
        for _ in 0 ..< 400 where told.isEmpty { await Task.yield() }
        watch.stop()
        #expect(told == [true])
    }

    /// A run whose answer came while the person was away, now back in its field with the ready drop at the caret.
    private static func readyHere(unchanged: Bool, passReturn: @escaping () -> Void) throws -> AgentRun {
        let agent = agent(unchanged: unchanged)
        agent.passReturn = passReturn
        agent.snapshot = try snapshot("draft")
        agent.handle(.started); agent.handle(.focus(false)); agent.handle(.parkDue)
        agent.held = "answer"
        agent.handle(.answered); agent.handle(.focus(true))
        #expect(agent.flow.readyHere)
        return agent
    }

    private static func agent(unchanged: Bool = true) -> AgentRun {
        let owner = DropOwner()
        _ = owner.claim(.fix, busy: { true }) { AnyView(EmptyView()) }
        let agent = AgentRun(drop: AgentDrop(owner: owner) { _ in nil }, editor: EditorAccess(), runner: { throw ClaudeAgentError.notInstalled },
                             holdsFocus: { _ in false }, draftUnchanged: { _ in unchanged }, fullScreen: { _ in false })
        agent.cue = { _ in }
        return agent
    }

    private static func snapshot(_ text: String) throws -> EditorSnapshot {
        EditorSnapshot(element: AXUIElementCreateSystemWide(), pid: 1, hostPID: nil, appName: "Fixture", bundleID: nil, owner: "Fixture",
                       appVersion: nil, role: "AXTextArea", subrole: nil,
                       transaction: try TextTransaction(value: text, selection: NSRange(location: 0, length: 0)), geometry: .init(element: nil))
    }
}
