import XCTest
@testable import OopsCore

typealias CoordinatorInput = DictationCoordinator.InputEvent

let binding = "transcribe"
let otherBinding = "transcribe_with_post_process"
let holdThreshold: Duration = .milliseconds(300)

/// Whether an effect is a start or a stop, whatever its binding.
extension DictationCoordinator.Effect? {
    var isStart: Bool { if case .start = self { return true } else { return false } }
    var isStop: Bool { if case .stop = self { return true } else { return false } }
}

enum DriveEvent {
    /// A key-down event (real initial press or a synthesized auto-repeat press).
    case press
    /// A key-up event (synthesized auto-repeat release or the genuine key-up).
    case release
    /// The release grace window elapsed with no cancelling press arriving.
    case grace
}

struct DriveResult {
    var starts: Int
    var stops: Int
    var stage: DictationCoordinator.Stage
}

func pttInput(_ isPressed: Bool) -> CoordinatorInput {
    CoordinatorInput(
        bindingID: binding, hotkeyString: binding, isPressed: isPressed, mode: .pushToTalk,
        holdThreshold: .zero, external: false)
}

/// Feeds an event sequence to a real coordinator the way its owner would; effects are counted instead of
/// executed.
func drive(_ events: [DriveEvent]) -> DriveResult {
    var state = DictationCoordinator()
    var clock = ContinuousClock.now
    var starts = 0
    var stops = 0

    for ev in events {
        // Auto-repeat events arrive a few ms apart, well inside the debounce.
        clock += .milliseconds(5)

        let effect: DictationCoordinator.Effect?
        switch ev {
        case .grace: effect = state.onGraceExpired()
        case .press, .release:
            var isPressed = false
            if case .press = ev { isPressed = true }
            effect = state.onInput(pttInput(isPressed), now: clock)
        }
        switch effect {
        case .start: starts += 1
        case .stop: stops += 1
        case nil: break
        }
    }

    return DriveResult(starts: starts, stops: stops, stage: state.stage)
}

/// Initial press plus several synthesized release/press pairs, as X11 emits while a push-to-talk key is
/// held down.
func autorepeatBurst() -> [DriveEvent] {
    var events: [DriveEvent] = [.press]
    for _ in 0..<6 {
        events.append(.release)
        events.append(.press)
    }
    return events
}

func toggleInput(_ external: Bool) -> CoordinatorInput {
    toggleInputFor(binding, external)
}

func toggleInputFor(_ bindingID: String, _ external: Bool) -> CoordinatorInput {
    CoordinatorInput(
        bindingID: bindingID, hotkeyString: bindingID, isPressed: true, mode: .toggle,
        holdThreshold: .zero, external: external)
}

/// Start and stop one toggle recording so the machine sits in `processing`.
func driveIntoProcessing(_ state: inout DictationCoordinator, _ now: ContinuousClock.Instant) {
    var effect = state.onInput(toggleInput(true), now: now)
    XCTAssertTrue(effect.isStart)
    effect = state.onInput(toggleInput(true), now: now + .milliseconds(100))
    XCTAssertTrue(effect.isStop)
    XCTAssertEqual(state.stage, .processing)
}

func input(_ mode: DictationCoordinator.Activation, _ isPressed: Bool) -> CoordinatorInput {
    CoordinatorInput(
        bindingID: binding, hotkeyString: binding, isPressed: isPressed, mode: mode,
        holdThreshold: holdThreshold, external: false)
}

func ms(_ n: Int64) -> Duration { .milliseconds(n) }

/// Hold-vs-tap classification while the previous transcription is busy.
func holdOrToggleIntoProcessing(_ state: inout DictationCoordinator, _ t0: ContinuousClock.Instant) {
    let mode = DictationCoordinator.Activation.holdOrToggle
    XCTAssertTrue(state.onInput(input(mode, true), now: t0).isStart)
    XCTAssertNil(state.onInput(input(mode, false), now: t0 + ms(800)))
    XCTAssertTrue(state.onGraceExpired().isStop)
    XCTAssertEqual(state.stage, .processing)
}
