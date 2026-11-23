import Foundation
@testable import Oops
import OopsCore
import Testing

/// What a working agent run's drop and menu say, and what its done drop says, from the run's progress. No drop is
/// shown: these runs never start.
@MainActor struct AgentRunProgressTests {
    private static let start = ContinuousClock.now
    private static func at(_ seconds: Double) -> ContinuousClock.Instant { start + .milliseconds(Int(seconds * 1000)) }

    @Test func `the opening names the action, with how long it usually takes once that is known`() {
        let usual = [Duration.seconds(60), .seconds(62), .seconds(58)]
        let known = AgentProgress(start: Self.start, usual: usual), new = AgentProgress(start: Self.start)
        #expect(AgentRun.label(known.status(at: Self.at(0)), name: "Ambition") == "Ambition · usually about 1 min")
        #expect(AgentRun.label(new.status(at: Self.at(0)), name: "Ambition") == "Ambition")
        #expect(AgentRun.label(known.status(at: Self.at(2)), name: "Ambition") == "Ambition", "the note is gone after 2 s")
    }

    @Test func `working labels carry no ellipsis of their own`() {
        var progress = AgentProgress(start: Self.start)
        progress.handle(.step(.searching("q")), at: Self.at(2))
        #expect(AgentRun.label(progress.status(at: Self.at(2)), name: "Ambition") == "Searching “q”")
        progress.handle(.step(.reading("example.com")), at: Self.at(4))
        #expect(AgentRun.label(progress.status(at: Self.at(4)), name: "Ambition") == "Reading example.com")
        // Words that are cut, or still going, end in the ellipsis they already have, and no second one.
        progress.handle(.step(.summary("Searched the web for three sources and compared…")), at: Self.at(6))
        #expect(AgentRun.label(progress.status(at: Self.at(6)), name: "Ambition") == "Searched the web for three sources and compared…")
        #expect(AgentRun.label(progress.status(at: Self.at(26)), name: "Ambition") == "Still working…")
    }

    @Test func `the done drop says what the run did, cut at a word to sit beside the time`() {
        #expect(AgentRun.done("Ambition", summary: nil, elapsed: .seconds(72)) == "Ambition · 1:12")
        #expect(AgentRun.done("Ambition", summary: "Added plan structure and checks", elapsed: .seconds(72))
            == "Added plan structure and checks · 1:12")
        let long = "Added a plan structure, per-field checks, and a monitoring table with thresholds"
        let short = AgentRun.short(long)
        #expect(short == "Added a plan structure, per-field checks, and…")
        #expect(short.count <= AgentRun.summaryLength)
        #expect(AgentRun.short(String(repeating: "x", count: 60)).count == AgentRun.summaryLength)
    }

    @Test func `only a usable answer joins the action's history`() throws {
        let suite = "oops-agent-progress-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let history = AgentRunHistory(defaults: defaults), action = UUID()
        let agent = AgentRun(drop: AgentDrop(owner: DropOwner()) { _ in nil }, editor: EditorAccess(),
                             runner: { throw ClaudeAgentError.notInstalled }, history: history)

        // An answer that can't be read: its time is noted on arrival, and the run fails before keeping it.
        let rejected = #"{"text":""}"#
        agent.begin(action, at: Self.at(0))
        agent.heard(.answer(rejected), at: Self.at(3))
        #expect(throws: ActionOutputError.empty) { try ActionPrompt.decode(rejected, draft: "draft") }
        #expect(history.durations(for: action).isEmpty)

        agent.begin(action, at: Self.at(10))
        agent.heard(.step(.thinking), at: Self.at(11))
        agent.heard(.activity, at: Self.at(12))
        agent.heard(.summary("Cut it to one line"), at: Self.at(13))
        agent.heard(.answer(#"{"text":"new"}"#), at: Self.at(14))
        #expect(history.durations(for: action).isEmpty, "kept only once the answer is read")
        agent.keepTime()
        #expect(history.durations(for: action) == [.seconds(4)])
        #expect(agent.progress?.summary == "Cut it to one line")

        // Cancelled or failed before answering: nothing about how long the action takes.
        agent.begin(action, at: Self.at(20))
        agent.heard(.step(.thinking), at: Self.at(21))
        agent.keepTime()
        #expect(history.durations(for: action) == [.seconds(4)])

        // Typed instructions have no action to remember.
        agent.begin(nil, at: Self.at(30))
        agent.heard(.answer("{}"), at: Self.at(35))
        agent.keepTime()
        #expect(defaults.dictionary(forKey: AgentRunHistory.key)?.count == 1)
    }

    @Test func `the opening note goes on time even when no update arrives`() async throws {
        let suite = "oops-agent-progress-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let history = AgentRunHistory(defaults: defaults), action = UUID()
        for seconds in [60, 62, 58] {
            var past = AgentProgress(start: Self.start)
            past.handle(.answer("{}"), at: Self.start + .seconds(seconds))
            history.record(past, for: action)
        }
        let agent = AgentRun(drop: AgentDrop(owner: DropOwner()) { _ in nil }, editor: EditorAccess(),
                             runner: { throw ClaudeAgentError.notInstalled }, history: history)
        let begun = ContinuousClock.now - .milliseconds(1800)
        agent.begin(action, at: begun)
        agent.handle(.started)
        defer { agent.cancel() }
        #expect(agent.shown.hasSuffix("usually about 1 min"))
        #expect(agent.wake?.at == begun + AgentProgress.opening, "presenting the status schedules its next change")
        for _ in 0 ..< 100 where agent.shown.hasSuffix("usually about 1 min") { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!agent.shown.contains("usually"))
    }

    @Test func `a run's timer starts once, at its beginning`() {
        let agent = AgentRun(drop: AgentDrop(owner: DropOwner()) { _ in nil }, editor: EditorAccess(),
                             runner: { throw ClaudeAgentError.notInstalled })
        agent.begin(nil)
        let started = agent.drop.startedAt
        #expect(started != nil)
        agent.heard(.step(.thinking))
        agent.heard(.activity)
        #expect(agent.drop.startedAt == started, "updates never restart the timer")
        #expect(agent.drop.heard != nil)
    }
}
