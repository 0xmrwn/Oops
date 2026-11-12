import XCTest
@testable import OopsCore

/// Sequence-level coverage of auto-repeat bursts, the busy-pipeline and cancel paths, debounce and failed
/// starts, driven through the real machine.
///
/// Under X11 key auto-repeat, holding a push-to-talk key does not emit one long press. It emits the
/// initial press followed by a stream of synthesized release/press pairs, then a single genuine release on
/// key-up. Each release is deferred for a short grace window and cancelled when the matching auto-repeat
/// press arrives.
final class DictationCoordinatorSequenceTests: XCTestCase {
    /// A burst of X11 auto-repeat release/press pairs must not stop recording: the releases are coalesced
    /// and recording stays continuously active for the whole burst.
    func testX11AutorepeatBurstDoesNotToggleRecording() {
        let result = drive(autorepeatBurst())
        XCTAssertEqual(result.starts, 1, "recording should start exactly once")
        XCTAssertEqual(
            result.stops, 0, "synthesized auto-repeat releases must not stop recording mid-burst")
        XCTAssertEqual(
            result.stage, .recording(binding),
            "recording must remain active across the entire auto-repeat burst")
    }

    /// Complements the burst test: once the key is genuinely released and the grace window elapses with
    /// no re-press, recording stops exactly once. This proves the debounce only coalesces synthesized
    /// releases and does not wedge the coordinator or swallow the real key-up.
    func testGenuineReleaseAfterGraceStopsRecordingOnce() {
        var events = autorepeatBurst()
        events.append(.release) // genuine key-up
        events.append(.grace) // grace window elapses, no cancelling press
        let result = drive(events)
        XCTAssertEqual(result.starts, 1, "recording should start exactly once")
        XCTAssertEqual(result.stops, 1, "a genuine release should stop recording exactly once")
        XCTAssertEqual(result.stage, .processing)
    }

    /// A press while the pipeline is busy is remembered and starts recording once the pipeline drains.
    func testPressDuringProcessingStartsAfterDrain() {
        var state = DictationCoordinator()
        let now = ContinuousClock.now

        var effect = state.onInput(pttInput(true), now: now)
        XCTAssertTrue(effect.isStart)

        effect = state.onInput(pttInput(false), now: now + .milliseconds(100))
        XCTAssertNil(effect, "release should be deferred, not fired")

        effect = state.onGraceExpired()
        XCTAssertTrue(effect.isStop)

        effect = state.onInput(pttInput(true), now: now + .milliseconds(200))
        XCTAssertNil(effect, "busy pipeline must remember, not start")

        effect = state.onProcessingFinished()
        XCTAssertTrue(effect.isStart, "remembered press should start once the pipeline drains")
    }

    /// Two toggle presses inside one busy window net to no-op: nothing starts when the pipeline drains
    /// (toggle parity).
    func testTogglePressesDuringProcessingNetNoopAfterDrain() {
        var state = DictationCoordinator()
        let now = ContinuousClock.now

        var effect = state.onInput(pttInput(true), now: now)
        XCTAssertTrue(effect.isStart)
        effect = state.onInput(pttInput(false), now: now + .milliseconds(100))
        XCTAssertNil(effect)
        effect = state.onGraceExpired()
        XCTAssertTrue(effect.isStop)

        func toggle(_ state: inout DictationCoordinator, at: ContinuousClock.Instant) -> DictationCoordinator
            .Effect? {
            state.onInput(
                CoordinatorInput(
                    bindingID: binding, hotkeyString: binding, isPressed: true, mode: .toggle,
                    holdThreshold: .zero, external: true),
                now: at)
        }

        effect = toggle(&state, at: now + .milliseconds(200))
        XCTAssertNil(effect)
        effect = toggle(&state, at: now + .milliseconds(300))
        XCTAssertNil(effect)

        effect = state.onProcessingFinished()
        XCTAssertNil(effect, "even number of busy toggle presses must not start recording")
        XCTAssertEqual(state.stage, .idle)
    }

    /// Cancel while processing abandons a remembered press: the pipeline drains to idle and nothing starts.
    func testCancelDuringProcessingDropsRememberedPress() {
        var state = DictationCoordinator()
        let now = ContinuousClock.now

        var effect = state.onInput(pttInput(true), now: now)
        XCTAssertTrue(effect.isStart)
        effect = state.onInput(pttInput(false), now: now + .milliseconds(100))
        XCTAssertNil(effect)
        effect = state.onGraceExpired()
        XCTAssertTrue(effect.isStop)

        effect = state.onInput(pttInput(true), now: now + .milliseconds(200))
        XCTAssertNil(effect)

        state.onCancel(recordingWasActive: false)
        XCTAssertEqual(
            state.stage, .processing,
            "cancel must not reset mid-processing — the pipeline still finishes")

        effect = state.onProcessingFinished()
        XCTAssertNil(effect, "cancelled session must not spawn a deferred recording")
        XCTAssertEqual(state.stage, .idle)
    }

    /// Only one press can be pending. Once a binding has claimed it, a toggle for a different binding is
    /// ignored (as it is while recording) instead of replacing the remembered press, so the pending
    /// binding's parity holds: two transcribe toggles still net to no-op.
    func testDifferentBindingDoesNotReplacePendingPress() {
        var state = DictationCoordinator()
        let now = ContinuousClock.now
        driveIntoProcessing(&state, now)

        func at(_ ms: Int64) -> ContinuousClock.Instant { now + .milliseconds(ms) }
        XCTAssertNil(state.onInput(toggleInput(true), now: at(200)))
        XCTAssertNil(state.onInput(toggleInputFor(otherBinding, true), now: at(300)))
        XCTAssertNil(state.onInput(toggleInput(true), now: at(400)))

        let effect = state.onProcessingFinished()
        XCTAssertNil(
            effect,
            "two transcribe toggles net to no-op; the ignored post-process toggle must not start")
        XCTAssertEqual(state.stage, .idle)
    }

    /// The binding that claimed the pending press is the one that starts on drain, regardless of other
    /// bindings toggled in between.
    func testDrainStartsThePendingBindingNotALaterOne() {
        var state = DictationCoordinator()
        let now = ContinuousClock.now
        driveIntoProcessing(&state, now)

        func at(_ ms: Int64) -> ContinuousClock.Instant { now + .milliseconds(ms) }
        XCTAssertNil(state.onInput(toggleInput(true), now: at(200)))
        XCTAssertNil(state.onInput(toggleInputFor(otherBinding, true), now: at(300)))

        switch state.onProcessingFinished() {
        case .start(let bindingID, _)?: XCTAssertEqual(bindingID, binding)
        case let other: XCTFail("expected Start for '\(binding)', got \(String(describing: other))")
        }
    }

    /// External triggers fire on every edge by design (a signal sent on both key press and release). Two
    /// edges inside the debounce window must both be honoured, or the parity desyncs and recording wedges on.
    func testExternalEdgesInsideDebounceWindowAreNotDropped() {
        var state = DictationCoordinator()
        let now = ContinuousClock.now

        var effect = state.onInput(toggleInput(true), now: now)
        XCTAssertTrue(effect.isStart)

        effect = state.onInput(toggleInput(true), now: now + .milliseconds(5))
        XCTAssertTrue(effect.isStop, "second external edge inside DEBOUNCE must stop the recording")
        XCTAssertEqual(state.stage, .processing)
    }

    /// Physical keyboard presses keep the debounce: a repeat inside the window is still dropped and
    /// recording stays active.
    func testKeyboardPressInsideDebounceWindowIsStillDropped() {
        var state = DictationCoordinator()
        let now = ContinuousClock.now

        var effect = state.onInput(toggleInput(false), now: now)
        XCTAssertTrue(effect.isStart)

        effect = state.onInput(toggleInput(false), now: now + .milliseconds(5))
        XCTAssertNil(effect, "keyboard repeat inside DEBOUNCE must be debounced")
        XCTAssertEqual(state.stage, .recording(binding))
    }

    /// If the start effect fails to begin recording (microphone access denied), the optimistic transition
    /// rolls back to idle.
    func testFailedStartRollsBackToIdle() {
        var state = DictationCoordinator()

        let effect = state.onInput(pttInput(true), now: ContinuousClock.now)
        XCTAssertTrue(effect.isStart)

        state.onStartResult(bindingID: binding, started: false)
        XCTAssertEqual(state.stage, .idle)
    }
}
