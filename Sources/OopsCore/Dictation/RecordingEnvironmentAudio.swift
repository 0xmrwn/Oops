import Foundation

// Ported from Hex's `AudioBehaviorGuard`, `mute_output` and the media pause of
// `src/audio/recording_environment.rs` at v3.4.0 (MIT, github.com/anomalyco/hex). See THIRD_PARTY_NOTICES.md.

/// "Mute": the output's main volume at zero, given back on restore unless someone raised it meanwhile.
public final class OutputMute: RecordingEnvironmentHold {
    private let output: any OutputVolume
    private let previous: [Float]

    private init(output: any OutputVolume, previous: [Float]) {
        self.output = output
        self.previous = previous
    }

    public static func start(_ output: any OutputVolume?) -> OutputMute? {
        guard let output, let previous = output.read(), !previous.isEmpty,
              output.write(previous.map { _ in 0 }) else { return nil }
        return OutputMute(output: output, previous: previous)
    }

    /// A volume changed by hand while muted is left alone.
    public func restore() {
        guard output.read()?.allSatisfy({ $0 <= 0.001 }) == true else { return }
        _ = output.write(previous)
    }
}

/// A media player Oops may pause while recording and resume afterwards.
public enum MediaPlayer: String, CaseIterable, Sendable {
    case music = "Music"
    case spotify = "Spotify"
    case vlc = "VLC"

    public var name: String { rawValue }

    public init?(bundleID: String) {
        switch bundleID {
        case "com.apple.Music": self = .music
        case "com.spotify.client": self = .spotify
        case "org.videolan.vlc": self = .vlc
        default: return nil
        }
    }

    public var bundleID: String {
        switch self {
        case .music: "com.apple.Music"
        case .spotify: "com.spotify.client"
        case .vlc: "org.videolan.vlc"
        }
    }

    /// The AppleScript condition that is true while the player is playing.
    var playingClause: String {
        switch self {
        case .music, .spotify: "player state is playing"
        case .vlc: "playing"
        }
    }

    var pauseFragment: String {
        "\ntry\n  if application \"\(name)\" is running then\n    tell application \"\(name)\"\n      if \(playingClause) then\n"
            + "        pause\n        set end of pausedPlayers to \"\(name)\"\n      end if\n    end tell\n  end if\nend try\n"
    }

    var resumeFragment: String {
        "try\n  if application \"\(name)\" is running then tell application \"\(name)\" to play\nend try"
    }
}

/// The players macOS reports as running, and a way to send them a script.
public protocol MediaPlayers: AnyObject {
    func running() -> Set<MediaPlayer>
    /// The script's output, or nil when it failed.
    func run(_ script: String) -> String?
}

/// "Pause media": the players that were playing, paused, and only those resumed.
public final class PausedMedia: RecordingEnvironmentHold {
    let players: [MediaPlayer]
    private let media: any MediaPlayers

    private init(players: [MediaPlayer], media: any MediaPlayers) {
        self.players = players
        self.media = media
    }

    /// Nil when nothing was paused, so nothing is resumed.
    public static func start(_ media: any MediaPlayers) -> PausedMedia? {
        holding(pause(media), media)
    }

    static func holding(_ players: [MediaPlayer], _ media: any MediaPlayers) -> PausedMedia? {
        players.isEmpty ? nil : PausedMedia(players: players, media: media)
    }

    static func pause(_ media: any MediaPlayers) -> [MediaPlayer] {
        let running = media.running()
        guard !running.isEmpty, let output = media.run(script(pausing: running)) else { return [] }
        return output.split(separator: ",").compactMap { MediaPlayer(rawValue: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    /// Never names a player that isn't running: telling it would launch it.
    static func script(pausing players: Set<MediaPlayer>) -> String {
        "set pausedPlayers to {}\n" + MediaPlayer.allCases.filter(players.contains).map(\.pauseFragment).joined() + "return pausedPlayers\n"
    }

    public func restore() {
        let running = media.running()
        let script = players.filter(running.contains).map(\.resumeFragment).joined(separator: "\n")
        guard !script.isEmpty else { return }
        _ = media.run(script)
    }
}
