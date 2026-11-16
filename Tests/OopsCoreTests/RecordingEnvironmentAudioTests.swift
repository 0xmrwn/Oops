import Foundation
@testable import OopsCore
import Testing

/// Players that answer a pause with the ones that were playing, and record every script.
final class FakeMediaPlayers: MediaPlayers, @unchecked Sendable {
    var runningPlayers: Set<MediaPlayer>
    var playing: [MediaPlayer]
    private(set) var scripts: [String] = []

    init(running: Set<MediaPlayer>, playing: [MediaPlayer]) {
        runningPlayers = running
        self.playing = playing
    }

    func running() -> Set<MediaPlayer> { runningPlayers }

    func run(_ script: String) -> String? {
        scripts.append(script)
        return script.hasPrefix("set pausedPlayers") ? playing.filter(runningPlayers.contains).map(\.name).joined(separator: ", ") : ""
    }
}

struct RecordingEnvironmentAudioTests {
    // Ported from Hex's `a_pause_with_nothing_paused_holds_nothing`, without its browser half.
    @Test func `a pause with nothing paused holds nothing`() {
        let media = FakeMediaPlayers(running: [], playing: [])
        #expect(PausedMedia.holding([], media) == nil)
        #expect(PausedMedia.holding([.music], media) != nil)
        #expect(PausedMedia.start(media) == nil)
        #expect(media.scripts.isEmpty, "nothing running: no script at all")
    }

    // Ported from Hex's test of the same name.
    @Test func `pause script never resolves players that are not running`() {
        let script = PausedMedia.script(pausing: [.music, .spotify])
        #expect(script.contains("application \"Music\""))
        #expect(script.contains("application \"Spotify\""))
        #expect(!script.contains("application \"VLC\""))

        let vlc = PausedMedia.script(pausing: [.vlc])
        #expect(vlc == """
        set pausedPlayers to {}

        try
          if application "VLC" is running then
            tell application "VLC"
              if playing then
                pause
                set end of pausedPlayers to "VLC"
              end if
            end tell
          end if
        end try
        return pausedPlayers

        """)
        #expect(!vlc.contains("player state is playing"))
        #expect(PausedMedia.script(pausing: [.music]).contains("if player state is playing then"))
    }

    @Test func `pausing resumes only the players it paused that still run`() throws {
        let media = FakeMediaPlayers(running: [.music, .spotify, .vlc], playing: [.spotify, .vlc])
        let paused = try #require(PausedMedia.start(media))
        #expect(paused.players == [.spotify, .vlc])
        media.runningPlayers = [.music, .spotify]
        paused.restore()
        let resume = try #require(media.scripts.last)
        #expect(resume.contains("tell application \"Spotify\" to play"))
        #expect(!resume.contains("Music"), "Music wasn't playing")
        #expect(!resume.contains("VLC"), "VLC quit meanwhile")
    }

    @Test func `a pause that failed holds nothing`() {
        final class Failing: MediaPlayers {
            func running() -> Set<MediaPlayer> { [.music] }
            func run(_ script: String) -> String? { nil }
        }
        #expect(PausedMedia.start(Failing()) == nil)
    }

    @Test func `muting restores the volume unless it was changed by hand`() throws {
        let output = FakeOutput([0.6])
        let muted = try #require(OutputMute.start(output))
        #expect(output.values == [0])
        muted.restore()
        #expect(output.values == [0.6])

        let raised = try #require(OutputMute.start(output))
        output.values = [0.3]
        raised.restore()
        #expect(output.values == [0.3])
    }

    @Test func `muting an output it cannot read or write holds nothing`() {
        #expect(OutputMute.start(nil) == nil)
        final class Unwritable: OutputVolume {
            func read() -> [Float]? { [0.5] }
            func write(_ values: [Float]) -> Bool { false }
        }
        #expect(OutputMute.start(Unwritable()) == nil)
    }
}
