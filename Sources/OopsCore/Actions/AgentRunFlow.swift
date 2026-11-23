import Foundation

/// An agent run as the person meets it: it works at the caret while they stay in the draft's field; once they have
/// been away for `parkDelay` its drop parks at the edge of the screen as a pill, and comes back to the caret when they
/// do. When it ends it either writes in place (still there) or waits as a ready result: in the parked pill, or at the
/// caret of its own field once they come back, where Return puts it in. One run at a time: a ready or returning run
/// still counts. Pure: the app turns each effect into the drop, the menu bar and the write.
public struct AgentRunFlow: Equatable, Sendable {
    public enum Phase: Equatable, Sendable { case idle, running, ready, returning }
    public enum MenuMark: Equatable, Sendable { case none, running, ready }
    /// Where the run's drop is: at its field's caret, or parked at the edge of the screen the person works on.
    public enum Place: Equatable, Sendable { case caret, parked }
    public enum Event: Equatable, Sendable {
        /// The draft is read and the agent has started, with the person in the field.
        case started
        /// Whether the person is in the run's field now.
        case focus(Bool)
        /// `parkDelay` has passed since `parkSoon`.
        case parkDue
        /// Whether the app in front is in native full screen, where the parked pill doesn't show.
        case fullScreen(Bool)
        case step(ClaudeAgentStep)
        case answered, failed, cancelled
        /// The ready result is wanted back in its draft, or thrown away.
        case act, dismiss
        /// Return, Escape, or a change to the draft, while the ready drop is at the caret of its field.
        case confirm, escape, edited
        /// The write the run ended with has finished, whatever it did.
        case settled
        /// Another feature's drop went away.
        case dropFree
    }
    public enum Effect: Equatable, Sendable {
        /// The run's drop at the caret, claiming it if it is free.
        case showStatus(ClaudeAgentStep)
        /// The person left the field: `parkDue` once `parkDelay` has passed. Coming back first leaves the drop be.
        case parkSoon
        /// The running drop flies to the parked pill.
        case park
        /// Hide the run's drop and give up its claim.
        case yieldDrop
        case menu(MenuMark)
        /// Finished in the field: written in place, as a slow Fix.
        case writeInPlace
        /// The ready drop in the parked pill, or the cue alone while another feature holds the drop.
        case announceReady
        /// Ready while the pill can't show (full screen): the sound alone says so.
        case chime
        /// The ready drop at the caret of its field, where Return puts it in.
        case readyAtCaret
        /// Written at the caret the person is already at.
        case putIn
        /// The draft changed under the ready drop: the answer is offered to copy.
        case offerCopy
        /// At the parked spot, or at the run's caret.
        case showFailure(parked: Bool)
        /// Bring back the draft's app, window and field, then write or offer Copy.
        case returnToDraft
        /// Forget the held answer.
        case discard
    }

    /// How long the person stays away before the drop parks: a quick ⌘-Tab and back moves nothing.
    public static let parkDelay: Duration = .milliseconds(400)

    public private(set) var phase = Phase.idle, inField = false, step = ClaudeAgentStep.starting
    public private(set) var place = Place.caret, fullScreen = false
    public var mark: MenuMark { phase == .running ? .running : phase == .ready ? .ready : .none }
    public var canStart: Bool { phase == .idle }
    /// At work at the caret with the person there: the run holds the drop.
    public var holdsDrop: Bool { phase == .running && inField && place == .caret }
    /// The ready drop is at the caret with the person in its field: Return puts it in, Escape parks it.
    public var readyHere: Bool { phase == .ready && inField && place == .caret }

    public init() {}

    public mutating func handle(_ event: Event) -> [Effect] {
        switch (phase, event) {
        case (.idle, .started):
            phase = .running; inField = true; step = .starting; place = .caret; fullScreen = false
            return [.menu(.running), .showStatus(.starting)]
        case let (.running, .focus(now)), let (.ready, .focus(now)):
            guard now != inField else { return [] }
            inField = now
            guard now else { return place == .caret ? [.parkSoon] : [] }
            // Back within `parkDelay`: the drop never left.
            guard place == .parked else { return [] }
            place = .caret
            return phase == .running ? [.showStatus(step)] : [.readyAtCaret]
        case (.running, .parkDue), (.ready, .parkDue):
            guard !inField, place == .caret else { return [] }
            place = .parked
            return pill()
        case let (.running, .fullScreen(now)), let (.ready, .fullScreen(now)):
            guard now != fullScreen else { return [] }
            fullScreen = now
            guard place == .parked else { return [] }
            return now ? [.yieldDrop] : pill()
        case let (.running, .step(next)):
            step = next
            return holdsDrop ? [.showStatus(next)] : []
        case (.running, .dropFree):
            if place == .parked { return fullScreen ? [] : [.park] }
            return inField ? [.showStatus(step)] : []
        case (.running, .answered):
            if holdsDrop {
                phase = .returning
                return [.menu(.none), .writeInPlace]
            }
            // Gone, or on the way out: the result waits in the pill, never at the caret of another field.
            phase = .ready; place = .parked
            return [.menu(.ready)] + (fullScreen ? [.yieldDrop, .chime] : [.announceReady])
        case (.running, .failed):
            phase = .idle
            return [.menu(.none), .showFailure(parked: place == .parked)]
        case (.running, .cancelled):
            phase = .idle
            return [.menu(.none), .yieldDrop]
        case (.ready, .dropFree):
            if place == .parked { return fullScreen ? [] : [.announceReady] }
            return inField ? [.readyAtCaret] : []
        case (.ready, .act):
            let here = readyHere
            phase = .returning
            return [.menu(.none), here ? .putIn : .returnToDraft]
        case (.ready, .confirm):
            guard readyHere else { return [] }
            phase = .returning
            return [.menu(.none), .putIn]
        case (.ready, .escape):
            guard readyHere else { return [] }
            place = .parked
            return pill()
        case (.ready, .edited):
            guard readyHere else { return [] }
            phase = .idle
            return [.menu(.none), .offerCopy]
        case (.ready, .dismiss):
            phase = .idle
            return [.menu(.none), .discard, .yieldDrop]
        case (.returning, .settled):
            phase = .idle
            return []
        default:
            return []
        }
    }

    /// The run's drop at the parked spot, unless full screen keeps it hidden there.
    private func pill() -> [Effect] {
        fullScreen ? [.yieldDrop] : [phase == .running ? .park : .announceReady]
    }
}

public extension ClaudeAgentStep {
    /// What the agent is doing, in a few words for the drop and the menu.
    var label: String {
        switch self {
        case .starting: "Starting"
        case .thinking: "Thinking it through"
        case let .searching(query): "Searching “\(Self.short(query))”"
        case let .reading(host): "Reading \(Self.short(host))"
        case .readingResults: "Reading what it found"
        case .running: "Running a command"
        case let .usingSkill(skill): "Using \(Self.short(skill))"
        // Claude Code already cut it to fit, with its own ellipsis.
        case let .summary(text): text
        case .writing: "Writing the new draft"
        // The answer is in, but whether it is written depends on where the person is now.
        case .done: "Finishing"
        }
    }

    /// Short enough that a typical query fits the agent's drop whole: a longer one is cut with an ellipsis, and the
    /// drop cuts anything still too wide for it at a word.
    private static func short(_ text: String) -> String {
        text.count > 36 ? text.prefix(35).trimmingCharacters(in: .whitespaces) + "…" : text
    }
}
