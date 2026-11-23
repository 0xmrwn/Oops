import Foundation

/// What an agent run's drop shows from moment to moment, every word of it true: each step stays up long enough to
/// read, the drop calms down when nothing has arrived for a while and says so if it lasts, and the opening says how
/// long the action usually takes. The app owns one per run and feeds it every update as it arrives.
/// Pure: time is always given, never read.
public struct AgentProgress: Equatable, Sendable {
    public typealias Instant = ContinuousClock.Instant

    /// What to show at a given moment.
    public struct Status: Equatable, Sendable {
        /// The step on show.
        public var step: ClaudeAgentStep
        /// Words that stand in for the step's label: how long the action usually takes, at the start, or that the run
        /// is still going, after a long quiet.
        public var note: String?
        /// Nothing has arrived for a few seconds: the drop slows down and looks around.
        public var calm: Bool
        public var elapsed: Duration
        public var label: String { note ?? step.label }
    }

    /// A label stays up at least this long; a newer step waits for it, and only the latest waiting one shows.
    public static let hold: Duration = .milliseconds(1500)
    /// How long the opening note shows.
    public static let opening: Duration = .seconds(2)
    public static let calmAfter: Duration = .seconds(5), stillAfter: Duration = .seconds(20)
    /// Fewer answered runs than this say nothing about how long the action takes.
    public static let enough = 3

    public let start: Instant
    private let hint: String?, longest: Duration?
    private var shown = ClaudeAgentStep.starting, holdUntil: Instant, pending: ClaudeAgentStep?
    /// When the last update arrived. Quiet only counts once something has.
    private var heard: Instant?
    /// What the run did, in Claude Code's words, once it has said.
    public private(set) var summary: String?
    /// How long the run took to answer, once it has.
    public private(set) var answered: Duration?

    /// `usual`: how long this action's recent answered runs took, from `AgentRunHistory`.
    public init(start: Instant, usual: [Duration] = []) {
        self.start = start
        hint = Self.hint(usual)
        longest = usual.count >= Self.enough ? usual.max() : nil
        holdUntil = start + (hint == nil ? Self.hold : Self.opening)
    }

    public mutating func handle(_ update: ClaudeAgentUpdate, at time: Instant) {
        heard = time
        switch update {
        case let .step(step):
            settle(at: time)
            if time >= holdUntil { show(step, at: time) } else { pending = step == shown ? nil : step }
        case .activity: break
        case let .summary(text): summary = text
        case .answer: answered = start.duration(to: time)
        }
    }

    public func status(at time: Instant) -> Status {
        var now = self
        now.settle(at: time)
        let quiet = heard.map { $0.duration(to: time) } ?? .zero
        var note: String?
        if quiet >= Self.stillAfter {
            note = longerThanUsual(at: time) ? "Taking longer than usual" : "Still working…"
        } else if time < start + Self.opening {
            note = hint
        }
        return Status(step: now.shown, note: note, calm: quiet >= Self.calmAfter, elapsed: start.duration(to: time))
    }

    /// The next moment `status` may change with no new update, for the app to look again then. The elapsed time
    /// ticks on regardless.
    public func nextChange(after time: Instant) -> Instant? {
        var times = hint == nil ? [] : [start + Self.opening]
        if pending != nil { times.append(holdUntil) }
        if let heard { times += [heard + Self.calmAfter, heard + Self.stillAfter] }
        if let longest { times.append(start + longest * 1.25) }
        return times.filter { $0 > time }.min()
    }

    /// Past the longest of the action's recent runs, with some room: never said without enough of them.
    public func longerThanUsual(at time: Instant) -> Bool {
        guard let longest else { return false }
        // From the very moment `nextChange` names, so a consumer woken then sees it.
        return start.duration(to: time) >= longest * 1.25
    }

    /// How long the action usually takes, from the median of its recent answered runs, to the nearest minute.
    public static func hint(_ usual: [Duration]) -> String? {
        guard usual.count >= enough else { return nil }
        let sorted = usual.sorted(), middle = sorted.count / 2
        let median = sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
        let seconds = median / .seconds(1)
        return seconds < 45 ? "usually under a minute" : "usually about \(Int((seconds / 60).rounded())) min"
    }

    /// A step that waited shows the moment the one before it has been up long enough.
    private mutating func settle(at time: Instant) {
        guard let pending, time >= holdUntil else { return }
        show(pending, at: holdUntil)
    }

    private mutating func show(_ step: ClaudeAgentStep, at time: Instant) {
        pending = nil
        guard step != shown else { return }
        shown = step
        holdUntil = time + Self.hold
    }
}
