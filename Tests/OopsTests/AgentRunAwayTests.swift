import ApplicationServices
import Foundation
@testable import Oops
import OopsCore
import os
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

    @Test func `Return taken for the ready drop puts the answer in`() async throws {
        let agent = try Self.readyHere()
        agent.pressed(.confirm)
        for _ in 0 ..< 200 where agent.flow.phase != .idle { await Task.yield() }
        #expect(agent.flow.phase == .idle)
    }

    @Test func `no key is taken while another feature holds the drop`() throws {
        let agent = try Self.readyHere()
        #expect(!agent.takes(.confirm))
        #expect(!agent.takes(.escape))
        #expect(!agent.confirming, "no tap is armed for a drop that isn't up")
    }

    @Test func `no key is taken with no ready drop at the caret`() {
        let agent = Self.agent()
        agent.handle(.started)
        #expect(!agent.takes(.confirm))
    }

    @Test func `Escape taken for the ready drop parks it rather than cancelling anything`() throws {
        let agent = try Self.readyHere()
        agent.pressed(.escape)
        #expect(agent.isReady && agent.flow.place == .parked)
        #expect(agent.held == "answer")
    }

    @Test func `a draft changed while another feature holds the drop keeps the answer ready`() throws {
        let agent = try Self.readyHere()
        agent.handle(.edited)
        // The copy offer couldn't claim the drop: nothing is lost, and the menu still offers the result.
        #expect(agent.isReady && agent.flow.stale && agent.flow.mark == .ready)
        #expect(agent.held == "answer" && agent.copyable == nil)
        agent.dismiss()
        #expect(!agent.isReady)
    }

    @Test func `a check that doesn't answer in time decides nothing`() {
        #expect(AgentRun.bounded(.milliseconds(20)) { () -> Bool in Thread.sleep(forTimeInterval: 0.3); return true } == nil)
        #expect(AgentRun.bounded(.seconds(2)) { true } == true)
    }

    @Test func `the watch tells the full screen of the app in front, once asked and as it changes`() async throws {
        let full = OSAllocatedUnfairLock(initialState: true)
        let watch = AgentFocusWatch(holds: { _ in false }, fullScreen: { pid in pid == 42 && full.withLock { $0 } }, frontmost: { 42 })
        watch.start(try Self.snapshot("draft"))
        defer { watch.stop() }
        let first = await withCheckedContinuation { told in
            watch.screenChanged = { watch.screenChanged = { _ in }; told.resume(returning: $0) }
            watch.watchesScreen = true
        }
        #expect(first)
        full.withLock { $0 = false }
        let second = await withCheckedContinuation { told in
            watch.screenChanged = { watch.screenChanged = { _ in }; told.resume(returning: $0) }
            watch.tick()
        }
        #expect(!second)
    }

    /// A run whose answer came while the person was away, now back in its field with the ready drop at the caret.
    private static func readyHere() throws -> AgentRun {
        let agent = agent()
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
