import AppKit
import os
import OopsCore

/// Whether macOS lets Oops send Apple events to a player, which Pause media needs to pause and resume it.
enum MediaPlayerAutomation: Equatable, Sendable {
    case allowed
    case refused
    /// Never asked: asking would open macOS's "Oops wants access to control …" dialog.
    case undetermined
    /// Not running, or no answer macOS can give: nothing to ask or report.
    case unknown

    /// macOS's answer, asking with its dialog when `asking` and the player was never asked. Asking blocks until the
    /// person answers, so it runs off the main thread, and only from Settings: never during a dictation.
    static func system(_ player: MediaPlayer, asking: Bool) -> MediaPlayerAutomation {
        guard let target = NSAppleEventDescriptor(bundleIdentifier: player.bundleID).aeDesc else { return .unknown }
        let status = AEDeterminePermissionToAutomateTarget(target, typeWildCard, typeWildCard, asking)
        if status == noErr { return .allowed }
        if status == OSStatus(errAEEventNotPermitted) { return .refused }
        if status == OSStatus(errAEEventWouldRequireUserConsent) { return .undetermined }
        return .unknown
    }
}

/// macOS's answer without asking, given up after a limit. Reading it waits on the player itself, and a player that
/// never answers (a long-running Spotify can) would otherwise hold Pause media, and every restore queued behind it,
/// for good. A player whose last reading is still waiting is unknown at once, so stuck readings never pile up.
final class MediaPlayerReading: Sendable {
    private let read: @Sendable (MediaPlayer) -> MediaPlayerAutomation
    private let limit: Duration
    private let waiting = OSAllocatedUnfairLock<Set<MediaPlayer>>(initialState: [])

    init(limit: Duration = .milliseconds(500), read: @escaping @Sendable (MediaPlayer) -> MediaPlayerAutomation) {
        self.limit = limit
        self.read = read
    }

    static let system = MediaPlayerReading { MediaPlayerAutomation.system($0, asking: false) }

    func answer(_ player: MediaPlayer) -> MediaPlayerAutomation {
        guard waiting.withLock({ $0.insert(player).inserted }) else { return .unknown }
        let answer = OSAllocatedUnfairLock<MediaPlayerAutomation?>(initialState: nil), done = DispatchSemaphore(value: 0)
        Thread.detachNewThread { [read, waiting] in
            let result = read(player)
            answer.withLock { $0 = result }
            waiting.withLock { _ = $0.remove(player) }
            done.signal()
        }
        let seconds = Double(limit.components.seconds) + Double(limit.components.attoseconds) / 1e18
        guard done.wait(timeout: .now() + seconds) == .success else { return .unknown }
        return answer.withLock { $0 } ?? .unknown
    }
}

/// Pause media's Settings side: asks macOS for each running player while the person is choosing, so a dictation
/// never has to, and names the players it refused. The players and macOS's answers come in, so tests use fakes.
struct MediaPlayerPermissions: Sendable {
    var running: @MainActor @Sendable () -> Set<MediaPlayer>
    var automation: @Sendable (MediaPlayer, _ asking: Bool) -> MediaPlayerAutomation

    static let system = MediaPlayerPermissions(running: { SystemMediaPlayers.runningPlayers() }) { player, asking in
        asking ? MediaPlayerAutomation.system(player, asking: true) : MediaPlayerReading.system.answer(player)
    }

    /// The running players macOS refused, after asking for each one never asked when `asking`.
    @MainActor func refused(asking: Bool) async -> [MediaPlayer] { await refused(among: running(), asking: asking) }

    /// Off the main thread: asking blocks while the dialog is up.
    @concurrent func refused(among players: Set<MediaPlayer>, asking: Bool) async -> [MediaPlayer] {
        MediaPlayer.allCases.filter(players.contains).filter { player in
            var answer = automation(player, false)
            if asking, answer == .undetermined { answer = automation(player, true) }
            return answer == .refused
        }
    }

    /// The card's line for refused players, or nil when there are none.
    static func problem(_ refused: [MediaPlayer]) -> String? {
        guard let last = refused.last?.name else { return nil }
        let names = refused.count == 1 ? last : refused.dropLast().map(\.name).joined(separator: ", ") + " and " + last
        return "To pause \(names), allow Oops under Automation in System Settings."
    }
}
