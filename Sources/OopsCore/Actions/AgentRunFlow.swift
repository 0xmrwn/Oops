import Foundation

/// An agent run as the person meets it: it works at the caret while they stay in the draft's field, lets go of the
/// drop when they leave, and when it ends either writes in place (still there) or waits as a ready result (gone
/// elsewhere) until they act on it or dismiss it. One run at a time: a ready or returning run still counts.
/// Pure: the app turns each effect into the drop, the menu bar and the write.
public struct AgentRunFlow: Equatable, Sendable {
    public enum Phase: Equatable, Sendable { case idle, running, ready, returning }
    public enum MenuMark: Equatable, Sendable { case none, running, ready }
    public enum Event: Equatable, Sendable {
        /// The draft is read and the agent has started, with the person in the field.
        case started
        /// Whether the person is in the run's field now.
        case focus(Bool)
        case step(ClaudeAgentStep)
        case answered, failed, cancelled
        /// The ready result is wanted back in its draft, or thrown away.
        case act, dismiss
        /// The write the run ended with has finished, whatever it did.
        case settled
        /// Another feature's drop went away.
        case dropFree
    }
    public enum Effect: Equatable, Sendable {
        /// The run's drop at the caret, claiming it if it is free.
        case showStatus(ClaudeAgentStep)
        /// Hide the run's drop and give up its claim.
        case yieldDrop
        case menu(MenuMark)
        /// Finished in the field: written in place, as a slow Fix.
        case writeInPlace
        /// The ready drop where the person is, or the cue alone while another feature holds the drop.
        case announceReady
        /// `here`: where the person is now; otherwise at the caret.
        case showFailure(here: Bool)
        /// Bring back the draft's app, window and field, then write or offer Copy.
        case returnToDraft
        /// Forget the held answer.
        case discard
    }

    public private(set) var phase = Phase.idle, inField = false, step = ClaudeAgentStep.starting
    public var mark: MenuMark { phase == .running ? .running : phase == .ready ? .ready : .none }
    public var canStart: Bool { phase == .idle }

    public init() {}

    public mutating func handle(_ event: Event) -> [Effect] {
        switch (phase, event) {
        case (.idle, .started):
            phase = .running; inField = true; step = .starting
            return [.menu(.running), .showStatus(.starting)]
        case let (.running, .focus(now)):
            guard now != inField else { return [] }
            inField = now
            return now ? [.showStatus(step)] : [.yieldDrop]
        case let (.running, .step(next)):
            step = next
            return inField ? [.showStatus(next)] : []
        case (.running, .dropFree):
            return inField ? [.showStatus(step)] : []
        case (.running, .answered):
            if inField {
                phase = .returning
                return [.menu(.none), .writeInPlace]
            }
            phase = .ready
            return [.menu(.ready), .announceReady]
        case (.running, .failed):
            phase = .idle
            return [.menu(.none), .showFailure(here: !inField)]
        case (.running, .cancelled):
            phase = .idle
            return [.menu(.none), .yieldDrop]
        case (.ready, .dropFree):
            return [.announceReady]
        case (.ready, .act):
            phase = .returning
            return [.menu(.none), .returnToDraft]
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

    /// Short enough for the drop at the caret: a long query is cut with an ellipsis.
    private static func short(_ text: String) -> String { text.count > 28 ? String(text.prefix(27)) + "…" : text }
}
