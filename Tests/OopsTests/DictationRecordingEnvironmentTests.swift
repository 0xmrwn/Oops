import Foundation
@testable import Oops
import OopsCore
import Synchronization
import XCTest

/// "While dictating" from the shortcut: the session over fakes, with an environment that only records what it
/// would change. Key events carry real instants here, since the environment waits on the hold threshold in real time.
@MainActor final class DictationRecordingEnvironmentTests: XCTestCase {
    final class Journal: Sendable {
        private let entries = Mutex<[String]>([])
        func append(_ entry: String) { entries.withLock { $0.append(entry) } }
        var all: [String] { entries.withLock { $0 } }
    }

    final class Recorded: RecordingEnvironmentHold {
        let effect: RecordingEnvironmentEffect, journal: Journal
        init(_ effect: RecordingEnvironmentEffect, _ journal: Journal) { self.effect = effect; self.journal = journal }
        func restore() { journal.append("restored \(effect)") }
    }

    private func environment(_ choice: DictationWhileDictating) -> (DictationRecordingEnvironment, RecordingEnvironmentController, Journal) {
        let journal = Journal()
        let controller = RecordingEnvironmentController { effect in
            journal.append("held \(effect)")
            return Recorded(effect, journal)
        }
        return (DictationRecordingEnvironment(controller: controller, choice: { choice }), controller, journal)
    }

    func testRecordingEnvironmentLeavesTheOutputAloneForATapThatNeverBecomesARecording() async throws {
        let (environment, controller, journal) = environment(.mute)
        let run = try DictationSessionRun(self, mode: .holdOrDoubleTap, environment: environment)
        // In the future, so the hold threshold can't pass while the tap is handled.
        let pressed = ContinuousClock.now + .seconds(5)
        run.session.shortcut(.pressed, at: DictationSessionRun.origin + .milliseconds(400), now: pressed)
        run.session.shortcut(.released, at: DictationSessionRun.origin + .milliseconds(520), now: pressed + .milliseconds(120))
        try await run.until { run.drop.states.last == .left }
        try await run.settle()
        _ = controller.waitUntilRestored(timeout: .seconds(2))
        XCTAssertEqual(run.drop.states, [.recording, .left])
        XCTAssertEqual(journal.all, [])
    }

    func testRecordingEnvironmentAppliesTheChoiceToAHeldRecordingAndRestoresItOnRelease() async throws {
        for choice in [DictationWhileDictating.mute, .lowerAudio, .pauseMedia] {
            let (environment, controller, journal) = environment(choice)
            let run = try DictationSessionRun(self, mode: .holdOnly, environment: environment)
            let pressed = ContinuousClock.now - .milliseconds(1_200)
            run.session.shortcut(.pressed, at: DictationSessionRun.origin + .milliseconds(400), now: pressed)
            try await run.until { _ = controller.waitUntilRestored(timeout: .seconds(2)); return journal.all.count == 1 }
            run.session.shortcut(.released, at: DictationSessionRun.origin + .milliseconds(1_600), now: .now)
            try await run.until { run.drop.states.last == .left }
            _ = controller.waitUntilRestored(timeout: .seconds(2))
            let effect: RecordingEnvironmentEffect = choice == .mute ? .mute : choice == .lowerAudio ? .duck : .pause
            XCTAssertEqual(journal.all, ["held \(effect)", "restored \(effect)"], "\(choice)")
        }
    }

    func testRecordingEnvironmentHoldsUntilTheReleaseTailIsCaptured() async throws {
        let (environment, controller, journal) = environment(.pauseMedia)
        // The microphone has heard up to the release and nothing after: the tail is waited for, past its bound.
        let heard = Array(DictationSessionRun.speech().prefix(25_600))
        let run = try DictationSessionRun(self, mode: .holdOnly, audio: heard, environment: environment) {
            ChangingSource($0, from: DictationSessionRun.origin)
        }
        let pressed = ContinuousClock.now - .milliseconds(1_200)
        run.session.shortcut(.pressed, at: DictationSessionRun.origin + .milliseconds(400), now: pressed)
        try await run.until { _ = controller.waitUntilRestored(timeout: .seconds(2)); return journal.all == ["held pause"] }
        run.session.shortcut(.released, at: DictationSessionRun.origin + .milliseconds(1_600), now: .now)
        try await run.until { run.drop.states.last == .transcribing }
        try await Task.sleep(for: .milliseconds(100))
        _ = controller.waitUntilRestored(timeout: .seconds(2))
        XCTAssertEqual(journal.all, ["held pause"], "media stays paused while the tail is captured")
        try await run.until { run.drop.states.last == .left }
        _ = controller.waitUntilRestored(timeout: .seconds(2))
        XCTAssertEqual(journal.all, ["held pause", "restored pause"])
    }

    func testRecordingEnvironmentRestoresACancelledRecording() async throws {
        let (environment, controller, journal) = environment(.mute)
        let run = try DictationSessionRun(self, mode: .tapOnly, environment: environment)
        let pressed = ContinuousClock.now - .seconds(1)
        run.session.shortcut(.pressed, at: DictationSessionRun.origin + .milliseconds(400), now: pressed)
        run.session.shortcut(.released, at: DictationSessionRun.origin + .milliseconds(450), now: pressed + .milliseconds(50))
        try await run.until { _ = controller.waitUntilRestored(timeout: .seconds(2)); return journal.all == ["held mute"] }
        run.session.cancel()
        try await run.until { run.drop.states.last == .left }
        _ = controller.waitUntilRestored(timeout: .seconds(2))
        XCTAssertEqual(journal.all, ["held mute", "restored mute"])
    }

    func testRecordingEnvironmentDoNothingHoldsNothing() async throws {
        let (environment, controller, journal) = environment(.nothing)
        environment.recordingStarted(pressedAt: .now - .seconds(1))
        try await Task.sleep(for: .milliseconds(100))
        environment.recordingEnded()
        _ = controller.waitUntilRestored(timeout: .seconds(2))
        XCTAssertEqual(journal.all, [])
    }

    func testRecordingEnvironmentRestoresBeforeQuit() async throws {
        let (environment, _, journal) = environment(.lowerAudio)
        environment.recordingStarted(pressedAt: .now - .seconds(1))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(environment.restoreBeforeQuit(timeout: .seconds(2)))
        XCTAssertEqual(journal.all, ["held duck", "restored duck"])
    }
}
