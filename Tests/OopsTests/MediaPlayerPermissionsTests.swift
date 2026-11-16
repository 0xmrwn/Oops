@testable import Oops
import OopsCore
import Synchronization
import XCTest

/// Pause media's Settings side over fake players and answers: macOS's permission system is never called.
final class MediaPlayerPermissionsTests: XCTestCase {
    /// macOS as a table of answers that turns a player's undetermined answer into its reply once asked.
    final class FakeAutomation: Sendable {
        private let answers: Mutex<[MediaPlayer: MediaPlayerAutomation]>
        private let replies: [MediaPlayer: MediaPlayerAutomation]
        private let asked = Mutex<[MediaPlayer]>([])

        init(_ answers: [MediaPlayer: MediaPlayerAutomation], replies: [MediaPlayer: MediaPlayerAutomation] = [:]) {
            self.answers = Mutex(answers); self.replies = replies
        }

        var askedPlayers: [MediaPlayer] { asked.withLock { $0 } }

        func answer(_ player: MediaPlayer, asking: Bool) -> MediaPlayerAutomation {
            answers.withLock { answers in
                let answer = answers[player] ?? .unknown
                guard asking, answer == .undetermined else { return answer }
                asked.withLock { $0.append(player) }
                answers[player] = replies[player] ?? .undetermined
                return answers[player] ?? .undetermined
            }
        }

        func permissions(running: Set<MediaPlayer>) -> MediaPlayerPermissions {
            MediaPlayerPermissions(running: { running }, automation: { self.answer($0, asking: $1) })
        }
    }

    func testAskingAsksOnlyTheRunningPlayersNeverAskedAndReportsTheRefusedInOrder() async {
        let macOS = FakeAutomation([.music: .undetermined, .spotify: .refused, .vlc: .undetermined], replies: [.music: .refused, .vlc: .allowed])
        let refused = await macOS.permissions(running: [.vlc, .spotify, .music]).refused(asking: true)
        XCTAssertEqual(macOS.askedPlayers, [.music, .vlc])
        XCTAssertEqual(refused, [.music, .spotify])
    }

    func testAPlayerThatIsNotRunningIsNeitherAskedNorReported() async {
        let macOS = FakeAutomation([.music: .refused, .spotify: .undetermined])
        let refused = await macOS.permissions(running: [.vlc]).refused(asking: true)
        XCTAssertEqual(macOS.askedPlayers, [])
        XCTAssertEqual(refused, [])
    }

    func testReadingNeverAsksAndANeverAskedPlayerIsNotReportedAsRefused() async {
        let macOS = FakeAutomation([.music: .undetermined, .spotify: .allowed, .vlc: .refused], replies: [.music: .refused])
        let refused = await macOS.permissions(running: Set(MediaPlayer.allCases)).refused(asking: false)
        XCTAssertEqual(macOS.askedPlayers, [])
        XCTAssertEqual(refused, [.vlc])
    }

    func testTheCardSaysNothingWithoutARefusedPlayerAndNamesEachOneOtherwise() {
        XCTAssertNil(MediaPlayerPermissions.problem([]))
        XCTAssertEqual(MediaPlayerPermissions.problem([.spotify]), "To pause Spotify, allow Oops under Automation in System Settings.")
        XCTAssertEqual(MediaPlayerPermissions.problem([.music, .vlc]), "To pause Music and VLC, allow Oops under Automation in System Settings.")
        XCTAssertEqual(
            MediaPlayerPermissions.problem(MediaPlayer.allCases),
            "To pause Music, Spotify and VLC, allow Oops under Automation in System Settings."
        )
    }
}
