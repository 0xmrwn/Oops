import Foundation

// A port of Handy's `transcription_coordinator.rs` at 73cc857 (MIT, github.com/cjpais/handy): the pure
// state machine without its Tauri shell. See THIRD_PARTY_NOTICES.md.

/// Pure lifecycle state machine of a dictation session: owns every transition decision (release grace,
/// hold-versus-tap classification, debounce, busy-pipeline remember/forget, cancel, drain). It returns
/// `Effect`s instead of performing them, so tests drive the production transitions without timers.
///
/// All three activation modes run through one machine. A recording starts on key-down in every mode; what
/// differs is how it ends:
///
/// * push-to-talk: every release stops (hold threshold of zero)
/// * toggle: releases are ignored, the next press stops (locked from the start)
/// * hold-or-toggle: a release after a long hold stops; a release after a short tap locks the session,
///   and the next press stops
public struct DictationCoordinator: Sendable {
    /// How a shortcut's key events drive a recording.
    public enum Activation: Sendable, Equatable {
        /// Press to start, press again to stop.
        case toggle
        /// Hold to record, release to stop.
        case pushToTalk
        /// Hold to record and release to stop, or tap to keep recording until the next press. Which one it
        /// was is decided by how long the key was held.
        case holdOrToggle
    }

    /// Pipeline lifecycle.
    public enum Stage: Sendable, Equatable {
        case idle
        case recording(String) // binding id
        case processing
    }

    /// A keyboard or signal edge for a dictation binding.
    public struct InputEvent: Sendable {
        public var bindingID: String
        public var hotkeyString: String
        public var isPressed: Bool
        public var mode: Activation
        /// Hold-or-toggle: minimum press duration that counts as a hold.
        public var holdThreshold: Duration
        /// External triggers (signals, command-line flags) rather than physical keys. They fire on every
        /// edge by design and must never be debounced: dropping one desyncs toggle parity and wedges
        /// recording on.
        public var external: Bool

        public init(
            bindingID: String, hotkeyString: String, isPressed: Bool, mode: Activation,
            holdThreshold: Duration, external: Bool
        ) {
            self.bindingID = bindingID
            self.hotkeyString = hotkeyString
            self.isPressed = isPressed
            self.mode = mode
            self.holdThreshold = holdThreshold
            self.external = external
        }

        /// The hold duration at or above which a release stops recording.
        func effectiveHoldThreshold() -> Duration {
            switch mode {
            case .holdOrToggle: holdThreshold
            // Every release stops; toggle never defers releases at all.
            case .pushToTalk, .toggle: .zero
            }
        }
    }

    /// A side effect decided by the machine; whoever owns it is the only executor.
    public enum Effect: Sendable, Equatable {
        case start(bindingID: String, hotkeyString: String)
        case stop(bindingID: String, hotkeyString: String)
    }

    enum PttAction: Equatable, Sendable {
        case passthrough
        case deferRelease
        case cancelRelease
    }

    /// A key-up deferred by `releaseGrace` so a synthesized auto-repeat press can cancel it. When the grace
    /// elapses the hold is resolved by `finishHold` (recording) or `finishPendingHold` (press remembered
    /// while busy).
    struct PendingRelease: Sendable {
        var bindingID: String
        var hotkeyString: String
        var deadline: ContinuousClock.Instant
        /// When the key actually went up. The hold duration is measured to this instant, not to the grace
        /// expiry.
        var releasedAt: ContinuousClock.Instant
        /// Holds at least this long stop recording; shorter ones lock it on. Push-to-talk passes zero so
        /// every release stops.
        var holdThreshold: Duration
    }

    /// A press that arrived while the pipeline was still busy processing the previous transcription.
    /// Toggle-style triggers flip state on every edge, so dropping a busy press desyncs the parity: the
    /// next edge starts a recording nobody will ever stop.
    struct PendingPress: Sendable {
        var bindingID: String
        var hotkeyString: String
        /// The real key-down time, so a hold that straddles the drain is still measured from when the user
        /// pressed, not from when recording began.
        var pressedAt: ContinuousClock.Instant
        /// The recording will start locked on when the pipeline drains: set from the start for toggle, and
        /// for hold-or-toggle once the key came back up within the threshold (a tap). An unlocked pending
        /// press is a key we believe is still held.
        var locked: Bool

        func remembered() -> Remembered { locked ? .locked : .held }
    }

    /// What kind of press is already waiting for the pipeline to drain.
    enum Remembered: Equatable, Sendable {
        /// The key is still down as far as we know.
        case held
        /// A toggle press or a classified tap: it will start a locked session.
        case locked
    }

    /// Bookkeeping for the key press that started the current recording.
    struct Hold: Sendable {
        var pressedAt: ContinuousClock.Instant
        /// Recording outlives the key: the next press stops it, releases are ignored. Always set for
        /// toggle; set for hold-or-toggle once a release has been classified as a tap.
        var locked: Bool
    }

    /// What to do with an input that arrives while the pipeline is busy (`Stage.processing`).
    enum BusyAction: Equatable, Sendable {
        /// Ignore the input entirely.
        case ignore
        /// Remember the press; start recording when the pipeline finishes.
        case remember
        /// This press cancels a previously remembered press: two presses during one busy window net to
        /// no-op, exactly as a press stops a locked session once recording.
        case forget
    }

    static let debounce: Duration = .milliseconds(30)
    static let releaseGrace: Duration = .milliseconds(50)

    public private(set) var stage: Stage = .idle
    var hold: Hold?
    var lastPress: ContinuousClock.Instant?
    var pendingRelease: PendingRelease?
    var pendingPress: PendingPress?

    public init() {}

    /// What to do with an input that arrives while the pipeline is busy. `remembered` is the press for the
    /// same binding already waiting for the pipeline to drain, if any.
    static func classifyBusyInput(isPressed: Bool, mode: Activation, remembered: Remembered?) -> BusyAction {
        switch (mode, isPressed, remembered) {
        // Toggle: presses alternate remember/forget to preserve parity.
        case (.toggle, true, .some): .forget
        case (.toggle, true, .none): .remember
        // Toggle mode ignores releases.
        case (.toggle, false, _): .ignore
        // Hold modes: a press while busy means the user is holding the key, so start as soon as the
        // pipeline drains. A press on a queued tap stops it (parity); a press while the key is already
        // down is a repeat.
        case (.pushToTalk, true, .none), (.holdOrToggle, true, .none): .remember
        case (.pushToTalk, true, .some(.locked)), (.holdOrToggle, true, .some(.locked)): .forget
        case (.pushToTalk, true, .some(.held)), (.holdOrToggle, true, .some(.held)): .ignore
        // Releases of a held pending press are deferred by the grace window before reaching here and
        // resolved by `finishPendingHold`; any other release (no press remembered, or already locked) is
        // noise.
        case (.pushToTalk, false, _), (.holdOrToggle, false, _): .ignore
        }
    }

    /// Decide whether a key-up should be deferred (so auto-repeat can cancel it) or a key-down cancels a
    /// deferred release. `holdToTalk` is whether a release currently ends the session: true for push-to-talk
    /// and for an unlocked hold-or-toggle session, false for toggle and a locked session. `heldBinding` is
    /// the binding whose key we believe is down: the one recording, or the one remembered while the
    /// pipeline is busy.
    static func classifyPttEvent(
        pendingReleaseBinding: String?, isPressed: Bool, holdToTalk: Bool, bindingID: String,
        heldBinding: String?
    ) -> PttAction {
        if !holdToTalk { return .passthrough }

        if isPressed {
            if pendingReleaseBinding == bindingID { return .cancelRelease }
            return .passthrough
        } else if heldBinding == bindingID, pendingReleaseBinding == nil {
            return .deferRelease
        }
        return .passthrough
    }

    /// Deadline of the deferred release, if any.
    public var graceDeadline: ContinuousClock.Instant? { pendingRelease?.deadline }

    /// Whether the current session (recording, or remembered for the drain) outlives the key, so releases
    /// are ignored and the next press ends it.
    public var isLocked: Bool { hold?.locked == true || pendingPress?.locked == true }

    /// A recording is running and outlives its key (a tap, or toggle mode).
    public var isRecordingLocked: Bool {
        if case .recording = stage { return hold?.locked == true }
        return false
    }

    public mutating func onInput(_ input: InputEvent, now: ContinuousClock.Instant) -> Effect? {
        let pendingReleaseBinding = pendingRelease?.bindingID
        let heldBinding: String? = switch stage {
        case .recording(let id): id
        case .processing: pendingPress?.bindingID
        case .idle: nil
        }
        let holdToTalk = input.mode != .toggle && !isLocked

        switch Self.classifyPttEvent(
            pendingReleaseBinding: pendingReleaseBinding,
            isPressed: input.isPressed,
            holdToTalk: holdToTalk,
            bindingID: input.bindingID,
            heldBinding: heldBinding
        ) {
        case .cancelRelease:
            pendingRelease = nil
            return nil
        case .deferRelease:
            pendingRelease = PendingRelease(
                bindingID: input.bindingID,
                hotkeyString: input.hotkeyString,
                deadline: now + Self.releaseGrace,
                releasedAt: now,
                holdThreshold: input.effectiveHoldThreshold()
            )
            return nil
        case .passthrough: break
        }

        // Debounce rapid-fire press events (key repeat / double-tap). Releases in the hold modes are
        // deferred above to absorb auto-repeat. External triggers are exempt: each one is a deliberate
        // edge from the user's own integration, and dropping it desyncs toggle parity.
        if input.isPressed, !input.external {
            if let last = lastPress, last.duration(to: now) < Self.debounce { return nil }
            lastPress = now
        }

        // A busy pipeline can't accept lifecycle changes now: classify the input against any
        // already-remembered press instead of dropping it silently.
        if case .processing = stage {
            // Only one press can be remembered. Once a binding has claimed it, inputs for a different
            // binding are ignored (the same rule as a different binding pressed while recording) rather
            // than silently replacing the remembered press and breaking its parity.
            if let pending = pendingPress, pending.bindingID != input.bindingID { return nil }
            let remembered = pendingPress?.remembered()
            switch Self.classifyBusyInput(isPressed: input.isPressed, mode: input.mode, remembered: remembered) {
            case .remember:
                pendingPress = PendingPress(
                    bindingID: input.bindingID,
                    hotkeyString: input.hotkeyString,
                    pressedAt: now,
                    // Toggle never ends on a release: locked from the start.
                    locked: input.mode == .toggle
                )
            case .forget:
                pendingPress = nil
            case .ignore: break
            }
            return nil
        }

        if input.isPressed {
            switch stage {
            case .idle:
                // Toggle never ends on a release: locked from the start.
                let locked = input.mode == .toggle
                return beginRecording(
                    bindingID: input.bindingID, hotkeyString: input.hotkeyString, pressedAt: now,
                    locked: locked)
            case .recording(let id) where id == input.bindingID:
                // A locked session ends on the next press. In toggle mode every press ends it, even if
                // the recording began under a hold mode (the setting changed mid-recording), otherwise
                // nothing but Escape could stop it.
                if isLocked || input.mode == .toggle {
                    return beginProcessing(bindingID: input.bindingID, hotkeyString: input.hotkeyString)
                }
            // The key is still held (its release will end this recording), so a repeated press means
            // nothing.
            default: break
            }
        } else if holdToTalk, case .recording(let id) = stage, id == input.bindingID {
            // A release that was not deferred (one is already pending for this binding): resolve it
            // immediately rather than dropping it.
            let threshold = input.effectiveHoldThreshold()
            return finishHold(
                bindingID: input.bindingID, hotkeyString: input.hotkeyString, releasedAt: now,
                threshold: threshold)
        }
        return nil
    }

    /// The `releaseGrace` window elapsed with no cancelling press arriving: resolve the deferred release
    /// against whatever that binding's key was holding, the live recording or a press remembered while busy.
    public mutating func onGraceExpired() -> Effect? {
        guard let pending = pendingRelease else { return nil }
        pendingRelease = nil
        switch stage {
        case .recording(let id) where id == pending.bindingID:
            return finishHold(
                bindingID: pending.bindingID, hotkeyString: pending.hotkeyString,
                releasedAt: pending.releasedAt, threshold: pending.holdThreshold)
        case .processing:
            finishPendingHold(pending)
            return nil
        default:
            return nil
        }
    }

    /// A press remembered while the pipeline was busy has been released for real, still before the drain. A
    /// completed hold has nothing left to start; a tap queues a locked session so the drain starts it, by
    /// the same hold-versus-tap rule as `finishHold`.
    private mutating func finishPendingHold(_ release: PendingRelease) {
        guard let pending = pendingPress, pending.bindingID == release.bindingID else { return }
        let held = max(.zero, pending.pressedAt.duration(to: release.releasedAt))
        if held < release.holdThreshold {
            pendingPress?.locked = true
        } else {
            pendingPress = nil
        }
    }

    /// The key that started the current recording has been released for real. A hold at least `threshold`
    /// long stops recording; anything shorter was a tap, which locks the session on until the next press.
    private mutating func finishHold(
        bindingID: String, hotkeyString: String, releasedAt: ContinuousClock.Instant, threshold: Duration
    ) -> Effect? {
        // No hold bookkeeping means we cannot tell a tap from a hold; stopping is the safe reading (it is
        // what push-to-talk always did).
        let unbounded = Duration(secondsComponent: Int64.max, attosecondsComponent: 0)
        let held = hold.map { max(.zero, $0.pressedAt.duration(to: releasedAt)) } ?? unbounded
        if held >= threshold {
            return beginProcessing(bindingID: bindingID, hotkeyString: hotkeyString)
        }
        if hold != nil { hold?.locked = true }
        return nil
    }

    public mutating func onCancel(recordingWasActive: Bool) {
        pendingRelease = nil
        // An explicit cancel abandons any remembered start too: the user asked for silence, not a deferred
        // recording.
        pendingPress = nil
        // Don't reset during processing; wait for the pipeline to finish.
        var processing = false
        if case .processing = stage { processing = true }
        var recording = false
        if case .recording = stage { recording = true }
        if !processing, recordingWasActive || recording {
            stage = .idle
            hold = nil
        }
    }

    /// Not Handy's: the recording's input went away (the microphone was unplugged, or the default input
    /// changed). The recording ends as its release would have ended it, and what was captured is transcribed;
    /// the key's own release, when it comes, finds the pipeline busy and is ignored.
    public mutating func onInputLost() -> Effect? {
        guard case .recording(let id) = stage else { return nil }
        pendingRelease = nil
        return beginProcessing(bindingID: id, hotkeyString: id)
    }

    public mutating func onProcessingFinished() -> Effect? {
        stage = .idle
        hold = nil
        guard let pending = pendingPress else { return nil }
        pendingPress = nil
        return beginRecording(
            bindingID: pending.bindingID, hotkeyString: pending.hotkeyString, pressedAt: pending.pressedAt,
            locked: pending.locked)
    }

    /// Reconcile the optimistic `Stage.recording` after the executor reports whether recording actually
    /// began (microphone access can be denied).
    public mutating func onStartResult(bindingID: String, started: Bool) {
        if !started, case .recording(let id) = stage, id == bindingID {
            stage = .idle
            hold = nil
        }
    }

    /// Optimistic transition to `Stage.recording`; rolled back via `onStartResult` if the effect fails to
    /// start recording for real.
    private mutating func beginRecording(
        bindingID: String, hotkeyString: String, pressedAt: ContinuousClock.Instant, locked: Bool
    ) -> Effect {
        stage = .recording(bindingID)
        hold = Hold(pressedAt: pressedAt, locked: locked)
        return .start(bindingID: bindingID, hotkeyString: hotkeyString)
    }

    private mutating func beginProcessing(bindingID: String, hotkeyString: String) -> Effect {
        stage = .processing
        hold = nil
        return .stop(bindingID: bindingID, hotkeyString: hotkeyString)
    }
}
