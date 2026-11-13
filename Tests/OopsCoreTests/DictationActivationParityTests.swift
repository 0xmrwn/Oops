import XCTest
@testable import OopsCore

/// Hold or tap, hold only and tap only answer exactly as `DictationCoordinator` driven directly with the same
/// events: same effects, same deadlines, same recording and latch state at every step.
final class DictationActivationParityTests: XCTestCase {
    private static let scripts: [String: [ActivationStep]] = [
        "long hold": [.press(0), .release(800), .timer, .finished],
        "tap then press": [.press(0), .release(120), .timer, .press(5000), .release(5080), .finished],
        "re-press inside the grace": [.press(0), .release(400), .press(420), .release(900), .timer, .finished],
        "release resolved without its grace": [.press(0), .release(100), .release(130), .timer],
        "held press during processing": [
            .press(0), .release(800), .timer, .press(1000), .finished, .release(1800), .timer, .finished,
        ],
        "tap during processing": [
            .press(0), .release(800), .timer, .press(1000), .release(1100), .timer, .finished, .press(3000),
            .release(3050), .timer,
        ],
        "drain inside a busy grace": [
            .press(0), .release(800), .timer, .press(1000), .release(1100), .finished, .timer, .press(3000),
        ],
        "two taps during processing": [
            .press(0), .release(800), .timer, .press(900), .release(950), .timer, .press(1000), .release(1050),
            .timer, .finished,
        ],
        "debounced press": [.press(0), .press(10), .release(20), .timer, .press(40), .release(500), .timer],
        "failed start": [.press(0), .startFailed, .release(100), .timer, .press(200), .release(800), .timer],
        "cancel a latch": [.press(0), .release(100), .timer, .cancel(recordingWasActive: true), .press(2000)],
        "cancel during processing": [
            .press(0), .release(800), .timer, .press(900), .cancel(recordingWasActive: false), .finished, .press(2000),
        ],
        "cancel inside the grace": [.press(0), .release(100), .cancel(recordingWasActive: true), .timer, .press(500)],
    ]

    func testThinModesMatchTheCoordinator() {
        for mode in [DictationMode.holdOrTap, .holdOnly, .tapOnly] {
            for (name, script) in Self.scripts {
                assertParity(mode, script, "\(mode) \(name)")
            }
        }
    }

    private func assertParity(_ mode: DictationMode, _ script: [ActivationStep], _ name: String) {
        guard let activationMode = mode.coordinatorActivation else { return XCTFail("\(mode) is not thin") }
        var drive = ActivationDriver(mode)
        var coordinator = DictationCoordinator()
        let id = "transcribe"
        func input(_ isPressed: Bool) -> DictationCoordinator.InputEvent {
            DictationCoordinator.InputEvent(
                bindingID: id, hotkeyString: id, isPressed: isPressed, mode: activationMode,
                holdThreshold: .milliseconds(300), external: false)
        }

        for (index, step) in script.enumerated() {
            let expected: DictationCoordinator.Effect?
            let effect: DictationActivation.Effect?
            switch step {
            case .press(let millis):
                expected = coordinator.onInput(input(true), now: drive.at(millis))
                effect = drive.press(millis)
            case .release(let millis):
                expected = coordinator.onInput(input(false), now: drive.at(millis))
                effect = drive.release(millis)
            case .timer:
                expected = coordinator.onGraceExpired()
                effect = drive.fire()
            case .startFailed:
                coordinator.onStartResult(bindingID: id, started: false)
                drive.activation.startResult(started: false)
                expected = nil
                effect = nil
            case .finished:
                expected = coordinator.onProcessingFinished()
                effect = drive.finished()
            case .cancel(let recordingWasActive):
                coordinator.onCancel(recordingWasActive: recordingWasActive)
                drive.activation.cancel(recordingWasActive: recordingWasActive)
                expected = nil
                effect = nil
            }
            let label = "\(name), step \(index) \(step)"
            XCTAssertEqual(effect, DictationActivation.Effect(expected), label)
            XCTAssertEqual(drive.deadline, coordinator.graceDeadline, label)
            XCTAssertEqual(drive.isRecording, coordinator.stage == .recording(id), label)
            XCTAssertEqual(drive.isLocked, coordinator.isRecordingLocked, label)
        }
    }
}
