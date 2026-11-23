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

    /// Running, with the person away long enough for the drop to have parked.
    private static let parked: [AgentRunFlow.Event] = [.focus(false), .parkDue]
    /// Finished while away: the ready pill.
    private static let ready: [AgentRunFlow.Event] = [.focus(false), .parkDue, .answered]
    /// Finished while away, then back in its field: the ready drop at the caret.
    private static let readyHere: [AgentRunFlow.Event] = [.focus(false), .parkDue, .answered, .focus(true)]
    private static func flow(_ events: [AgentRunFlow.Event], then more: AgentRunFlow.Event...) -> AgentRunFlow {
        var flow = AgentRunFlow()
        for event in [.started] + events + more { _ = flow.handle(event) }
        return flow
    }

    @Test func `starting puts the run at the caret, in the field`() {
        var flow = AgentRunFlow()
        #expect(flow.handle(.started) == [.menu(.running), .showStatus(.starting)])
        #expect(flow.phase == .running && flow.inField && flow.step == .starting && flow.place == .caret)
        #expect(flow.holdsDrop)
    }

    // MARK: Leaving and coming back while it runs

    @Test func `leaving the field parks the drop only once the person stays away`() {
        var flow = Self.flow()
        #expect(flow.handle(.focus(false)) == [.parkSoon])
        #expect(flow.place == .caret && !flow.inField && !flow.holdsDrop)
        #expect(flow.handle(.parkDue) == [.park])
        #expect(flow.place == .parked && flow.phase == .running)
    }

    @Test func `a quick trip away and back moves nothing`() {
        var flow = Self.flow(.focus(false))
        #expect(flow.handle(.focus(true)).isEmpty)
        #expect(flow.inField && flow.place == .caret)
        #expect(flow.handle(.parkDue).isEmpty, "the park it had asked for is no longer due")
        #expect(flow.place == .caret)
    }

    @Test func `coming back to the field flies the drop back with the current step`() {
        var flow = Self.flow(Self.parked, then: .step(.thinking))
        #expect(flow.handle(.focus(true)) == [.showStatus(.thinking)])
        #expect(flow.inField && flow.place == .caret && flow.holdsDrop)
    }

    @Test func `a step shows only while the run holds the drop at the caret`() {
        var here = Self.flow()
        #expect(here.handle(.step(.running)) == [.showStatus(.running)])
        #expect(here.step == .running)
        var leaving = Self.flow(.focus(false))
        #expect(leaving.handle(.step(.running)).isEmpty, "another feature may have the drop by now")
        var away = Self.flow(Self.parked)
        #expect(away.handle(.step(.running)).isEmpty)
        #expect(away.step == .running)
    }

    @Test func `a free drop takes the run back where it is`() {
        var here = Self.flow(.step(.thinking))
        #expect(here.handle(.dropFree) == [.showStatus(.thinking)])
        var leaving = Self.flow(.focus(false))
        #expect(leaving.handle(.dropFree).isEmpty, "it parks once the delay is up")
        var away = Self.flow(Self.parked)
        #expect(away.handle(.dropFree) == [.park])
    }

    // MARK: Full screen

    @Test func `full screen hides the parked pill until it ends`() {
        var flow = Self.flow(Self.parked)
        #expect(flow.handle(.fullScreen(true)) == [.yieldDrop])
        #expect(flow.handle(.dropFree).isEmpty)
        #expect(flow.handle(.fullScreen(false)) == [.park])
    }

    @Test func `full screen at the caret changes nothing until the drop parks`() {
        var flow = Self.flow()
        #expect(flow.handle(.fullScreen(true)).isEmpty)
        #expect(flow.handle(.focus(false)) == [.parkSoon])
        #expect(flow.handle(.parkDue) == [.yieldDrop])
        #expect(flow.place == .parked)
        #expect(flow.handle(.focus(true)) == [.showStatus(.starting)])
    }

    @Test func `finishing in full screen chimes and shows the ready pill once it ends`() {
        var flow = Self.flow(Self.parked, then: .fullScreen(true))
        #expect(flow.handle(.answered) == [.menu(.ready), .yieldDrop, .chime])
        #expect(flow.handle(.fullScreen(false)) == [.announceReady])
    }

    // MARK: Ending

    @Test func `an answer in the field writes in place`() {
        var flow = Self.flow()
        #expect(flow.handle(.answered) == [.menu(.none), .writeInPlace])
        #expect(flow.phase == .returning)
    }

    @Test func `an answer away is held ready in the pill`() {
        var flow = Self.flow(Self.parked)
        #expect(flow.handle(.answered) == [.menu(.ready), .announceReady])
        #expect(flow.phase == .ready && flow.place == .parked)
    }

    @Test func `an answer just after leaving goes to the pill, not the caret`() {
        var flow = Self.flow(.focus(false))
        #expect(flow.handle(.answered) == [.menu(.ready), .announceReady])
        #expect(flow.place == .parked)
        #expect(flow.handle(.parkDue).isEmpty)
    }

    @Test func `a failure says so where the drop is`() {
        var here = Self.flow()
        #expect(here.handle(.failed) == [.menu(.none), .showFailure(parked: false)])
        #expect(here.phase == .idle)
        var away = Self.flow(Self.parked)
        #expect(away.handle(.failed) == [.menu(.none), .showFailure(parked: true)])
        #expect(away.phase == .idle)
    }

    @Test func `a cancel lets go of the drop, at the caret or from the pill`() {
        var here = Self.flow()
        #expect(here.handle(.cancelled) == [.menu(.none), .yieldDrop])
        #expect(here.phase == .idle)
        var away = Self.flow(Self.parked)
        #expect(away.handle(.cancelled) == [.menu(.none), .yieldDrop])
        #expect(away.canStart)
    }

    // MARK: The ready result

    @Test func `a ready result announces itself again once the drop is free`() {
        var flow = Self.flow(Self.ready)
        #expect(flow.handle(.dropFree) == [.announceReady])
        #expect(flow.phase == .ready)
    }

    @Test func `acting on the ready pill returns to the draft`() {
        var flow = Self.flow(Self.ready)
        #expect(flow.handle(.act) == [.menu(.none), .returnToDraft])
        #expect(flow.phase == .returning)
    }

    @Test func `dismissing a ready result forgets it`() {
        var flow = Self.flow(Self.ready)
        #expect(flow.handle(.dismiss) == [.menu(.none), .discard, .yieldDrop])
        #expect(flow.phase == .idle)
    }

    @Test func `back in the field on their own, the ready drop flies to the caret`() {
        var flow = Self.flow(Self.ready)
        #expect(flow.handle(.focus(true)) == [.readyAtCaret])
        #expect(flow.place == .caret && flow.readyHere)
    }

    @Test func `Return at the caret puts it in`() {
        var flow = Self.flow(Self.readyHere)
        #expect(flow.handle(.confirm) == [.menu(.none), .putIn])
        #expect(flow.phase == .returning)
        #expect(flow.handle(.settled).isEmpty)
        #expect(flow.canStart)
    }

    @Test func `acting on the ready drop at the caret puts it in there`() {
        var flow = Self.flow(Self.readyHere)
        #expect(flow.handle(.act) == [.menu(.none), .putIn])
    }

    @Test func `Escape at the caret sends the ready drop back to the pill`() {
        var flow = Self.flow(Self.readyHere)
        #expect(flow.handle(.escape) == [.announceReady])
        #expect(flow.place == .parked && flow.inField && !flow.readyHere)
        #expect(flow.handle(.confirm).isEmpty, "Return no longer puts it in")
        // Leaving and coming back brings it to the caret again.
        #expect(flow.handle(.focus(false)).isEmpty)
        #expect(flow.handle(.focus(true)) == [.readyAtCaret])
    }

    @Test func `a changed draft offers the answer to copy`() {
        var flow = Self.flow(Self.readyHere)
        #expect(flow.handle(.edited) == [.menu(.none), .offerCopy])
        #expect(flow.phase == .idle)
    }

    @Test func `leaving the field again parks the ready drop`() {
        var flow = Self.flow(Self.readyHere)
        #expect(flow.handle(.focus(false)) == [.parkSoon])
        #expect(!flow.readyHere)
        #expect(flow.handle(.confirm).isEmpty, "Return reaches the app the person went to")
        #expect(flow.handle(.parkDue) == [.announceReady])
        #expect(flow.place == .parked)
    }

    @Test func `acting while leaving the caret returns to the draft`() {
        var flow = Self.flow(Self.readyHere, then: .focus(false))
        #expect(flow.handle(.act) == [.menu(.none), .returnToDraft])
    }

    @Test func `another feature's drop gives the ready drop back where it was`() {
        var here = Self.flow(Self.readyHere)
        #expect(here.handle(.dropFree) == [.readyAtCaret])
        var away = Self.flow(Self.ready, then: .fullScreen(true))
        #expect(away.handle(.dropFree).isEmpty)
    }

    @Test func `the write settling ends the run`() {
        var here = Self.flow(.answered)
        #expect(here.handle(.settled).isEmpty)
        #expect(here.phase == .idle)
        var returned = Self.flow(Self.ready, then: .act)
        #expect(returned.handle(.settled).isEmpty)
        #expect(returned.canStart)
    }

    @Test func `a new run starts at the caret, whatever the last one left`() {
        var flow = Self.flow(Self.ready, then: .fullScreen(true), .dismiss)
        #expect(flow.handle(.started) == [.menu(.running), .showStatus(.starting)])
        #expect(flow.place == .caret && !flow.fullScreen)
    }

    @Test(arguments: [
        ("idle", [AgentRunFlow.Event.focus(true), .focus(false), .parkDue, .fullScreen(true), .step(.thinking), .answered, .failed,
                                       .cancelled, .act, .dismiss, .confirm, .escape, .edited, .settled, .dropFree]),
        ("running", [.started, .act, .dismiss, .settled, .focus(true), .parkDue, .confirm, .escape, .edited]),
        ("parked", [.started, .focus(false), .parkDue, .act, .dismiss, .settled, .confirm, .escape, .edited, .fullScreen(false)]),
        ("ready", [.started, .focus(false), .parkDue, .step(.thinking), .answered, .failed, .cancelled, .confirm, .escape, .edited,
                   .settled, .fullScreen(false)]),
        ("readyHere", [.started, .focus(true), .parkDue, .step(.thinking), .answered, .failed, .cancelled, .settled]),
        ("returning", [.started, .focus(true), .focus(false), .parkDue, .fullScreen(true), .step(.thinking), .answered, .failed,
                       .cancelled, .act, .dismiss, .confirm, .escape, .edited, .dropFree]),
    ])
    func `other pairs change nothing`(state: String, events: [AgentRunFlow.Event]) {
        let start: AgentRunFlow = switch state {
        case "idle": AgentRunFlow()
        case "running": Self.flow()
        case "parked": Self.flow(Self.parked)
        case "ready": Self.flow(Self.ready)
        case "readyHere": Self.flow(Self.readyHere)
        default: Self.flow(.answered)
        }
        for event in events {
            var flow = start
            #expect(flow.handle(event).isEmpty, "\(state) ignores \(event)")
            #expect(flow == start)
        }
    }

    @Test func `only an idle flow can start another run`() {
        #expect(AgentRunFlow().canStart)
        #expect(!Self.flow().canStart)
        #expect(!Self.flow(Self.ready).canStart)
        #expect(!Self.flow(.answered).canStart)
    }

    @Test func `the menu mark follows the phase`() {
        #expect(AgentRunFlow().mark == .none)
        #expect(Self.flow().mark == .running)
        #expect(Self.flow(Self.parked).mark == .running)
        #expect(Self.flow(Self.ready).mark == .ready)
        #expect(Self.flow(Self.readyHere).mark == .ready)
        #expect(Self.flow(.answered).mark == .none)
    }

    @Test func `the step is kept across leaving and coming back`() {
        let flow = Self.flow(.step(.searching("swift")), .focus(false), .parkDue, .focus(true))
        #expect(flow.step == .searching("swift"))
    }

    @Test func `a step taken while away shows on return`() {
        var flow = Self.flow(Self.parked, then: .step(.searching("q")))
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
            == "Searching “how many moons does each planet of…”")
        // A typical query fits whole.
        #expect(ClaudeAgentStep.searching("prompt engineering best practices").label == "Searching “prompt engineering best practices”")
    }
}
