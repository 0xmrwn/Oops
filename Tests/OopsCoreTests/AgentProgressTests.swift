import Foundation
import Testing
@testable import OopsCore

/// The drop's pacing, at explicit times: holds, quiet, and the expectation from earlier runs.
struct AgentProgressTests {
    private static let start = ContinuousClock.now
    private static func at(_ seconds: Double) -> ContinuousClock.Instant { start + .milliseconds(Int(seconds * 1000)) }
    private static func runs(_ seconds: Int...) -> [Duration] { seconds.map { .seconds($0) } }

    /// A run that has seen `updates`, each at its time.
    private static func progress(usual: [Duration] = [], _ updates: (Double, ClaudeAgentUpdate)...) -> AgentProgress {
        var progress = AgentProgress(start: start, usual: usual)
        for (time, update) in updates { progress.handle(update, at: at(time)) }
        return progress
    }

    @Test func `a label holds for a moment and the latest waiting step wins`() {
        var progress = Self.progress((0, .step(.starting)), (0.5, .step(.thinking)), (1, .step(.searching("q"))))
        #expect(progress.status(at: Self.at(1.4)).step == .starting)
        #expect(progress.status(at: Self.at(1.5)).step == .searching("q"))
        progress.handle(.step(.reading("example.com")), at: Self.at(2))
        #expect(progress.status(at: Self.at(2.9)).step == .searching("q"))
        #expect(progress.status(at: Self.at(3)).step == .reading("example.com"))
        #expect(progress.nextChange(after: Self.at(2)) == Self.at(3))
    }

    @Test func `a step after the hold shows at once, and going back to the shown step drops the waiting one`() {
        var progress = Self.progress((0, .step(.starting)), (2, .step(.thinking)))
        #expect(progress.status(at: Self.at(2)).label == "Thinking it through")
        progress.handle(.step(.writing), at: Self.at(2.5))
        progress.handle(.step(.thinking), at: Self.at(3))
        #expect(progress.status(at: Self.at(4)).step == .thinking)
    }

    @Test func `quiet calms the drop at 5 s and says so at 20 s, until anything arrives`() {
        var progress = Self.progress((0, .step(.starting)), (1, .step(.thinking)))
        #expect(!progress.status(at: Self.at(5.9)).calm)
        #expect(progress.status(at: Self.at(6)).calm)
        #expect(progress.status(at: Self.at(20.9)).label == "Thinking it through")
        #expect(progress.status(at: Self.at(21)) == .init(step: .thinking, note: "Still working…", calm: true, elapsed: .seconds(21)))
        #expect(progress.nextChange(after: Self.at(6)) == Self.at(21))
        progress.handle(.activity, at: Self.at(22))
        #expect(progress.status(at: Self.at(22)) == .init(step: .thinking, note: nil, calm: false, elapsed: .seconds(22)))
    }

    @Test func `nothing is quiet before the run has been heard from`() {
        let status = AgentProgress(start: Self.start).status(at: Self.at(60))
        #expect(status == .init(step: .starting, note: nil, calm: false, elapsed: .seconds(60)))
    }

    @Test func `the opening says how long the action usually takes, for 2 s`() {
        let progress = Self.progress(usual: Self.runs(60, 62, 58), (0, .step(.starting)), (0.5, .step(.thinking)))
        #expect(progress.status(at: Self.at(0)).label == "usually about 1 min")
        #expect(progress.status(at: Self.at(1.9)) == .init(step: .starting, note: "usually about 1 min", calm: false, elapsed: .milliseconds(1900)))
        #expect(progress.status(at: Self.at(2)) == .init(step: .thinking, note: nil, calm: false, elapsed: .seconds(2)))
        #expect(AgentProgress(start: Self.start, usual: Self.runs(60, 60)).status(at: Self.at(0)).note == nil)
    }

    @Test func `the expectation rounds to whole minutes, from the median`() {
        let cases: [([Duration], String?)] = [
            (Self.runs(30, 30), nil), (Self.runs(44, 44, 44), "usually under a minute"), (Self.runs(45, 45, 45), "usually about 1 min"),
            (Self.runs(89, 89, 89), "usually about 1 min"), (Self.runs(90, 90, 90), "usually about 2 min"),
            (Self.runs(10, 100, 290), "usually about 2 min"), (Self.runs(30, 40, 50, 290), "usually about 1 min"),
            (Self.runs(200, 210, 220, 230, 240), "usually about 4 min"),
        ]
        for (usual, hint) in cases { #expect(AgentProgress.hint(usual) == hint) }
    }

    @Test func `a long quiet past the usual length says it is taking longer`() {
        let progress = Self.progress(usual: Self.runs(40, 50, 60), (0, .step(.starting)), (50, .activity))
        #expect(!progress.longerThanUsual(at: Self.at(75)))
        #expect(progress.longerThanUsual(at: Self.at(75.001)))
        #expect(progress.status(at: Self.at(74)).label == "Still working…")
        #expect(progress.status(at: Self.at(76)).label == "Taking longer than usual")
        let unknown = Self.progress(usual: Self.runs(40, 50), (0, .step(.starting)), (50, .activity))
        #expect(!unknown.longerThanUsual(at: Self.at(600)))
        #expect(unknown.status(at: Self.at(600)).label == "Still working…")
    }

    @Test func `the run keeps its summary and how long it took to answer`() {
        let progress = Self.progress((0, .step(.starting)), (30, .summary("Answered")), (31, .step(.done)), (31.5, .answer("{}")))
        #expect(progress.summary == "Answered")
        #expect(progress.answered == .milliseconds(31500))
        #expect(Self.progress((0, .step(.starting))).answered == nil)
    }
}

/// The last few answered runs of each action.
struct AgentRunHistoryTests {
    private let suite = "AgentRunHistoryTests." + UUID().uuidString

    private func answered(_ seconds: Int) -> AgentProgress {
        let start = ContinuousClock.now
        var progress = AgentProgress(start: start)
        progress.handle(.answer("{}"), at: start + .seconds(seconds))
        return progress
    }

    @Test func `keeps the last five answered runs of each action`() throws {
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let history = AgentRunHistory(defaults: defaults), action = UUID(), other = UUID()
        for seconds in 1 ... 7 { history.record(answered(seconds * 10), for: action) }
        history.record(answered(5), for: other)
        history.record(AgentProgress(start: .now), for: other)
        #expect(history.durations(for: action) == [30, 40, 50, 60, 70].map { .seconds($0) })
        #expect(AgentRunHistory(defaults: defaults).durations(for: other) == [.seconds(5)])
        #expect(history.durations(for: UUID()).isEmpty)
    }
}
