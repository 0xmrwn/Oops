import Foundation

/// How long each action's recent agent runs took to answer, for the drop's sense of how long to expect.
/// UserDefaults supports concurrent access to its individual reads and writes.
public struct AgentRunHistory: @unchecked Sendable {
    public static let key = "AgentRunDurations", kept = 5
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// The action's latest answered runs, oldest first.
    public func durations(for action: UUID) -> [Duration] {
        (stored[action.uuidString] ?? []).map { .milliseconds(Int64($0 * 1000)) }
    }

    /// Keeps the run's time only if it answered: a run that failed or was cancelled says nothing about how long the
    /// action takes.
    public func record(_ run: AgentProgress, for action: UUID) {
        guard let answered = run.answered else { return }
        var all = stored
        all[action.uuidString] = Array((all[action.uuidString] ?? []).suffix(Self.kept - 1)) + [answered / .seconds(1)]
        defaults.set(all, forKey: Self.key)
    }

    private var stored: [String: [Double]] { defaults.dictionary(forKey: Self.key) as? [String: [Double]] ?? [:] }
}
