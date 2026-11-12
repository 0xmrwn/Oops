import XCTest
@testable import OopsCore

/// Drives an activation on a synthetic clock: every time is milliseconds after `origin`.
struct ActivationDriver {
    var activation: DictationActivation
    let origin = ContinuousClock.now

    init(_ mode: DictationMode) {
        activation = DictationActivation(mode: mode)
    }

    func at(_ millis: Int64) -> ContinuousClock.Instant { origin + .milliseconds(millis) }

    mutating func press(_ millis: Int64) -> DictationActivation.Effect? { activation.pressed(at: at(millis)) }

    mutating func release(_ millis: Int64) -> DictationActivation.Effect? { activation.released(at: at(millis)) }

    /// Fires the timer at the deadline the activation asked for; nothing when it asked for none.
    mutating func fire() -> DictationActivation.Effect? {
        guard let deadline = activation.deadline else { return nil }
        return activation.timerFired(at: deadline)
    }

    mutating func finished() -> DictationActivation.Effect? { activation.processingFinished() }

    var isRecording: Bool { activation.isRecording }
    var isLocked: Bool { activation.isRecordingLocked }
    var deadline: ContinuousClock.Instant? { activation.deadline }
}

/// One step of a script played against both an activation and a coordinator.
enum ActivationStep {
    case press(Int64)
    case release(Int64)
    /// The pending deadline elapses.
    case timer
    case startFailed
    case finished
    case cancel(recordingWasActive: Bool)
}
