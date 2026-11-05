import XCTest
@testable import OopsCore

final class SoundCuesTests: XCTestCase {
    func testEnteringDropPlaysStartOnThePop() {
        let played = SoundCues.cue(from: nil, to: .starting, reduceMotion: false)
        XCTAssertEqual(played?.cue, .start); XCTAssertEqual(played?.delay, 0.075)
    }
    func testNewCorrectionOnAVisibleDropPlaysStartAsTheEyesTurn() {
        for previous: DropState in [.fixed, .failed, .quiet] {
            let played = SoundCues.cue(from: previous, to: .starting, reduceMotion: false)
            XCTAssertEqual(played?.cue, .start); XCTAssertEqual(played?.delay, 0.03)
        }
    }
    func testWorkingAfterInvokedStaysSilent() {
        XCTAssertNil(SoundCues.cue(from: .starting, to: .starting, reduceMotion: false))
    }
    func testOutcomesPlayOncePerChange() {
        XCTAssertEqual(SoundCues.cue(from: .starting, to: .fixed, reduceMotion: false)?.cue, .success)
        XCTAssertEqual(SoundCues.cue(from: .starting, to: .failed, reduceMotion: false)?.cue, .failure)
        XCTAssertNil(SoundCues.cue(from: .failed, to: .failed, reduceMotion: false))
        XCTAssertNil(SoundCues.cue(from: .fixed, to: .fixed, reduceMotion: false))
    }
    func testFailureCanEnterDirectly() {
        // "Nothing to revert" shows a failed drop that was hidden.
        XCTAssertEqual(SoundCues.cue(from: nil, to: .failed, reduceMotion: false)?.cue, .failure)
    }
    func testUsersOwnActionsAreSilent() {
        for previous: DropState? in [nil, .starting, .fixed, .failed] {
            XCTAssertNil(SoundCues.cue(from: previous, to: .quiet, reduceMotion: false))
        }
    }
    func testSuccessLandsTheLongNoteAsTheCheckArrives() {
        let delay = SoundCues.cue(from: .starting, to: .fixed, reduceMotion: false)!.delay
        // E6 peaks 99 ms into the file; the check's spring (0.5 s, bounce 0.32) is 90 % there at
        // 205 ms and crosses its target at 252 ms.
        XCTAssertGreaterThanOrEqual(delay + 0.099, 0.205); XCTAssertLessThanOrEqual(delay + 0.099, 0.252)
    }
    func testReduceMotionShortensTheLeadsToTheFadesMidpoints() {
        XCTAssertEqual(SoundCues.cue(from: .starting, to: .fixed, reduceMotion: true)?.delay, 0.05)
        XCTAssertEqual(SoundCues.cue(from: .starting, to: .failed, reduceMotion: true)?.delay, 0)
        XCTAssertEqual(SoundCues.cue(from: nil, to: .starting, reduceMotion: true)?.delay, 0.085)
    }
    func testTakesNeverRepeatBackToBack() {
        var cycle = TakeCycle()
        let takes = (0..<9).map { _ in cycle.next(.success) }
        XCTAssertEqual(Set(takes), [0, 1, 2])
        XCTAssertFalse(zip(takes, takes.dropFirst()).contains { $0 == $1 })
        XCTAssertEqual(cycle.next(.failure), 0, "each cue keeps its own turn")
    }
    func testStartIsOneVoice() {
        var cycle = TakeCycle()
        XCTAssertEqual((0..<3).map { _ in cycle.next(.start) }, [0, 0, 0])
        XCTAssertEqual(SoundCue.start.file(take: 0), "oops-start")
    }
    func testEveryTakeHasABundledFile() {
        let cues = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/Sounds")
        for cue in SoundCue.allCases {
            for take in 0..<cue.takes {
                let file = cues.appendingPathComponent(cue.file(take: take) + ".caf")
                XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), file.lastPathComponent)
            }
        }
    }
}
