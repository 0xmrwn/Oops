import Foundation

/// One shortcut's presses and releases, under a mode, as the moments a recording starts and ends.
///
/// Hold or tap, hold only and tap only are `DictationCoordinator`'s three activations; hold or double-tap is
/// `DictationDoubleTap`. The mode is read at a press that finds nothing under way, and that session (its
/// recording, its transcription and any press remembered meanwhile) keeps it to the end, so a change in Settings
/// never strands a recording: it still ends by the rules it started under.
public struct DictationActivation: Sendable {
    public enum Effect: Equatable, Sendable {
        /// Begin recording now.
        case start
        /// End the recording and transcribe it.
        case stop
        /// End the recording and write nothing (a lone quick tap in hold-or-double-tap).
        case discard
    }

    /// Hold or tap: a press held at least this long ends on its release; a shorter one latches recording on.
    public static let holdThreshold: Duration = .milliseconds(300)
    /// The coordinator keys its sessions by binding; this type is one shortcut.
    static let bindingID = "dictate"

    /// Read at each press: a change applies to the next press, never to a recording under way.
    public var mode: DictationMode
    /// The mode of the session under way, or of the last one.
    public private(set) var sessionMode: DictationMode
    private(set) var coordinator = DictationCoordinator()
    private(set) var doubleTap = DictationDoubleTap()

    public init(mode: DictationMode = .holdOrTap) {
        self.mode = mode
        sessionMode = mode
    }

    /// A recording, a transcription, a remembered press or a deferred release belongs to the current session.
    var isUnderWay: Bool {
        coordinator.stage != .idle || coordinator.graceDeadline != nil || !doubleTap.isIdle
    }

    public mutating func pressed(at now: ContinuousClock.Instant) -> Effect? {
        if !isUnderWay {
            // A double tap pairs only presses made under hold-or-double-tap.
            if sessionMode != mode { doubleTap = DictationDoubleTap() }
            sessionMode = mode
        }
        return edge(isPressed: true, at: now)
    }

    public mutating func released(at now: ContinuousClock.Instant) -> Effect? {
        edge(isPressed: false, at: now)
    }

    /// When `timerFired` must next be called, while a decision waits on time (a release's grace, a double
    /// tap's window).
    public var deadline: ContinuousClock.Instant? { coordinator.graceDeadline }

    public mutating func timerFired(at now: ContinuousClock.Instant) -> Effect? {
        guard let deadline, now >= deadline else { return nil }
        return Effect(coordinator.onGraceExpired())
    }

    /// Whether the recording a `.start` asked for really began (the microphone can be refused).
    public mutating func startResult(started: Bool) {
        coordinator.onStartResult(bindingID: Self.bindingID, started: started)
        doubleTap.startResult(started: started)
    }

    /// The transcription a `.stop` began is written or abandoned: a press remembered meanwhile may start now.
    public mutating func processingFinished() -> Effect? {
        if sessionMode.coordinatorActivation == nil { return doubleTap.processingFinished() }
        return Effect(coordinator.onProcessingFinished())
    }

    /// Drops everything, a recording included. `recordingWasActive` as in the coordinator's `onCancel`.
    public mutating func cancel(recordingWasActive: Bool) {
        coordinator.onCancel(recordingWasActive: recordingWasActive)
        doubleTap.cancel()
    }

    public var isRecording: Bool {
        if case .recording = coordinator.stage { return true }
        return doubleTap.isRecording
    }

    /// Recording continues with the keys up (latched by a tap, a double tap, or tap-only).
    public var isRecordingLocked: Bool { coordinator.isRecordingLocked || doubleTap.isLocked }

    private mutating func edge(isPressed: Bool, at now: ContinuousClock.Instant) -> Effect? {
        guard let activation = sessionMode.coordinatorActivation else {
            return isPressed ? doubleTap.pressed(at: now) : doubleTap.released(at: now)
        }
        let input = DictationCoordinator.InputEvent(
            bindingID: Self.bindingID, hotkeyString: Self.bindingID, isPressed: isPressed, mode: activation,
            holdThreshold: Self.holdThreshold, external: false)
        return Effect(coordinator.onInput(input, now: now))
    }
}

extension DictationActivation.Effect {
    init?(_ effect: DictationCoordinator.Effect?) {
        switch effect {
        case .start?: self = .start
        case .stop?: self = .stop
        case nil: return nil
        }
    }
}

extension DictationMode {
    /// The coordinator activation this mode is, or nil for hold-or-double-tap, which is not the coordinator's.
    var coordinatorActivation: DictationCoordinator.Activation? {
        switch self {
        case .holdOrTap: .holdOrToggle
        case .holdOnly: .pushToTalk
        case .tapOnly: .toggle
        case .holdOrDoubleTap: nil
        }
    }
}
