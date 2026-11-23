import Foundation
import Testing
@testable import OopsCore

/// Every row of the agent run's transitions, and the pairs it ignores.
struct AgentRunFlowTests {
    /// A flow that has started, then seen `events`.
    private static func flow(_ events: AgentRunFlow.Event...) -> AgentRunFlow {
        var flow = AgentRunFlow()
        _ = flow.handle(.started)
        for event in events { _ = flow.handle(event) }
        return flow
    }

    @Test func `starting puts the run at the caret, in the field`() {
        var flow = AgentRunFlow()
        #expect(flow.handle(.started) == [.menu(.running), .showStatus(.starting)])
        #expect(flow.phase == .running && flow.inField && flow.step == .starting)
    }

    @Test func `leaving the field lets go of the drop`() {
        var flow = Self.flow()
        #expect(flow.handle(.focus(false)) == [.yieldDrop])
        #expect(flow.phase == .running && !flow.inField)
    }

    @Test func `coming back shows the current step`() {
        var flow = Self.flow(.focus(false), .step(.thinking))
        #expect(flow.handle(.focus(true)) == [.showStatus(.thinking)])
        #expect(flow.inField)
    }

    @Test func `a step shows only in the field`() {
        var here = Self.flow()
        #expect(here.handle(.step(.running)) == [.showStatus(.running)])
        #expect(here.step == .running)
        var away = Self.flow(.focus(false))
        #expect(away.handle(.step(.running)).isEmpty)
        #expect(away.step == .running)
    }

    @Test func `a free drop takes the status back in the field`() {
        var flow = Self.flow(.step(.thinking))
        #expect(flow.handle(.dropFree) == [.showStatus(.thinking)])
        var away = Self.flow(.focus(false))
        #expect(away.handle(.dropFree).isEmpty)
    }

    @Test func `an answer in the field writes in place`() {
        var flow = Self.flow()
        #expect(flow.handle(.answered) == [.menu(.none), .writeInPlace])
        #expect(flow.phase == .returning)
    }

    @Test func `an answer away is held ready`() {
        var flow = Self.flow(.focus(false))
        #expect(flow.handle(.answered) == [.menu(.ready), .announceReady])
        #expect(flow.phase == .ready)
    }

    @Test func `a failure says so where the person is`() {
        var here = Self.flow()
        #expect(here.handle(.failed) == [.menu(.none), .showFailure(here: false)])
        #expect(here.phase == .idle)
        var away = Self.flow(.focus(false))
        #expect(away.handle(.failed) == [.menu(.none), .showFailure(here: true)])
        #expect(away.phase == .idle)
    }

    @Test func `a cancel lets go of the drop`() {
        var flow = Self.flow()
        #expect(flow.handle(.cancelled) == [.menu(.none), .yieldDrop])
        #expect(flow.phase == .idle)
    }

    @Test func `a ready result announces itself again once the drop is free`() {
        var flow = Self.flow(.focus(false), .answered)
        #expect(flow.handle(.dropFree) == [.announceReady])
        #expect(flow.phase == .ready)
    }

    @Test func `acting on a ready result returns to the draft`() {
        var flow = Self.flow(.focus(false), .answered)
        #expect(flow.handle(.act) == [.menu(.none), .returnToDraft])
        #expect(flow.phase == .returning)
    }

    @Test func `dismissing a ready result forgets it`() {
        var flow = Self.flow(.focus(false), .answered)
        #expect(flow.handle(.dismiss) == [.menu(.none), .discard, .yieldDrop])
        #expect(flow.phase == .idle)
    }

    @Test func `the write settling ends the run`() {
        var here = Self.flow(.answered)
        #expect(here.handle(.settled).isEmpty)
        #expect(here.phase == .idle)
        var returned = Self.flow(.focus(false), .answered, .act)
        #expect(returned.handle(.settled).isEmpty)
        #expect(returned.canStart)
    }

    @Test(arguments: [
        (AgentRunFlow.Phase.idle, [AgentRunFlow.Event.focus(true), .focus(false), .step(.thinking), .answered, .failed, .cancelled, .act, .dismiss,
                           .settled, .dropFree]),
        (.running, [.started, .act, .dismiss, .settled, .focus(true)]),
        (.ready, [.started, .focus(true), .focus(false), .step(.thinking), .answered, .failed, .cancelled, .settled]),
        (.returning, [.started, .focus(true), .focus(false), .step(.thinking), .answered, .failed, .cancelled, .act, .dismiss,
                      .dropFree]),
    ])
    func `other pairs change nothing`(phase: AgentRunFlow.Phase, events: [AgentRunFlow.Event]) {
        let start: AgentRunFlow = switch phase {
        case .idle: AgentRunFlow()
        case .running: Self.flow()
        case .ready: Self.flow(.focus(false), .answered)
        case .returning: Self.flow(.answered)
        }
        for event in events {
            var flow = start
            #expect(flow.handle(event).isEmpty, "\(phase) ignores \(event)")
            #expect(flow == start)
        }
    }

    @Test func `only an idle flow can start another run`() {
        #expect(AgentRunFlow().canStart)
        #expect(!Self.flow().canStart)
        #expect(!Self.flow(.focus(false), .answered).canStart)
        #expect(!Self.flow(.answered).canStart)
    }

    @Test func `the menu mark follows the phase`() {
        #expect(AgentRunFlow().mark == .none)
        #expect(Self.flow().mark == .running)
        #expect(Self.flow(.focus(false), .answered).mark == .ready)
        #expect(Self.flow(.answered).mark == .none)
    }

    @Test func `the step is kept across leaving and coming back`() {
        let flow = Self.flow(.step(.searching("swift")), .focus(false), .focus(true))
        #expect(flow.step == .searching("swift"))
    }

    @Test func `a step taken while away shows on return`() {
        var flow = Self.flow(.focus(false), .step(.searching("q")))
        #expect(flow.handle(.focus(true)) == [.showStatus(.searching("q"))])
    }

    @Test func `each step reads as what the agent is doing`() {
        #expect(ClaudeAgentStep.starting.label == "Starting")
        #expect(ClaudeAgentStep.thinking.label == "Thinking it through")
        #expect(ClaudeAgentStep.readingResults.label == "Reading what it found")
        #expect(ClaudeAgentStep.summary("Searching for moon counts per planet…").label == "Searching for moon counts per planet…")
        #expect(ClaudeAgentStep.writing.label == "Writing the new draft")
        #expect(ClaudeAgentStep.done.label == "Finishing")
        #expect(ClaudeAgentStep.searching("q").label == "Searching “q”")
        #expect(ClaudeAgentStep.reading("example.com").label == "Reading example.com")
        #expect(ClaudeAgentStep.running.label == "Running a command")
        #expect(ClaudeAgentStep.usingSkill("style").label == "Using style")
        #expect(ClaudeAgentStep.searching("how many moons does each planet of the solar system have").label
            == "Searching “how many moons does each pl…”")
    }
}
