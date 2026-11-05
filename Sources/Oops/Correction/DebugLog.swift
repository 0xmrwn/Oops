import Foundation
import OopsCore

/// Settings → About → Debug tools → Debug log. Off unless turned on; kept on this Mac only.
enum DebugLog {
    static let key = "DebugLog"
    /// `DebugLogDirectory` (a launch argument for end-to-end runs) keeps a run's log apart.
    static let store = DebugFlags.debugLogDirectory.map { DebugLogStore(directory: $0) } ?? DebugLogStore()
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: key) }

    static func record(_ attempt: DebugAttempt) {
        guard isEnabled else { return }
        store.append(.attempt(attempt))
    }

    static func recordRevert(of attempt: UUID) {
        guard isEnabled else { return }
        store.append(.revert(.init(attempt: attempt)))
    }

    static func recordReapply(of attempt: UUID) {
        guard isEnabled else { return }
        store.append(.reapply(.init(attempt: attempt)))
    }

    static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        Int((start.duration(to: .now) / .milliseconds(1)).rounded())
    }
}
