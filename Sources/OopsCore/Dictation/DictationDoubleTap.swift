import Foundation

// A port of the hold-or-double-tap path of Hex's dictation shortcut machine at v3.4.0 (MIT,
// github.com/anomalyco/hex): `DictationHotkey::process_event` in `src/suppression/hotkey.rs`, with
// `DOUBLE_TAP_WINDOW` from `src/suppression.rs` and the short-tap discard of `DictationCapture::would_transcribe`
// in `src/dictation.rs`. See THIRD_PARTY_NOTICES.md.

/// Hold or double-tap, for a shortcut with a key: every press starts recording; a release ends it, as a
/// discard when the press was shorter than the hold threshold. A release less than the double-tap window after
/// the previous recording's release locks the recording instead, and the next press ends it.
///
/// Every decision is made on an edge, as in Hex: a double tap is a discarded tap followed by a second press
/// whose recording locks at its release, so nothing waits on a timer.
struct DictationDoubleTap: Sendable {
    enum Stage: Sendable, Equatable {
        /// `lastRelease` is the release that ended the previous recording, kept while a press may still pair
        /// with it into a double tap.
        case idle(lastRelease: ContinuousClock.Instant?)
        /// The key is down. `previousRelease` is the release this press pairs with, if it came within the window.
        case recording(startedAt: ContinuousClock.Instant, previousRelease: ContinuousClock.Instant?)
        /// Recording with the key up, until the next press.
        case locked(startedAt: ContinuousClock.Instant)
        /// The last recording is being transcribed.
        case processing(lastRelease: ContinuousClock.Instant?)
    }

    /// A press made while the previous recording is still being transcribed, started when that finishes.
    struct PendingPress: Sendable, Equatable {
        /// The real key-down, so a hold that straddles the drain is measured from the press.
        var pressedAt: ContinuousClock.Instant
        var previousRelease: ContinuousClock.Instant?
        /// Released inside the window: the drain starts a locked recording.
        var locked: Bool
    }

    /// Hex's `MINIMUM_HOLD_DURATION`: a recording ended sooner than this after its press is a tap, written
    /// nowhere.
    static let holdThreshold: Duration = .milliseconds(300)
    /// Hex's `DOUBLE_TAP_WINDOW`, which is the hold threshold.
    static let doubleTapWindow: Duration = holdThreshold

    private(set) var stage: Stage = .idle(lastRelease: nil)
    private(set) var pendingPress: PendingPress?

    var isIdle: Bool {
        if case .idle = stage { return true }
        return false
    }

    var isRecording: Bool {
        switch stage {
        case .recording, .locked: true
        case .idle, .processing: false
        }
    }

    var isLocked: Bool {
        if case .locked = stage { return true }
        return false
    }

    /// `release` when `now` is still inside its double-tap window. Hex's clock saturates, so an edge stamped
    /// before the release counts as inside.
    static func pairing(_ release: ContinuousClock.Instant?, _ now: ContinuousClock.Instant) -> ContinuousClock
        .Instant? {
        guard let release, max(.zero, release.duration(to: now)) < doubleTapWindow else { return nil }
        return release
    }

    mutating func pressed(at now: ContinuousClock.Instant) -> DictationActivation.Effect? {
        switch stage {
        case .idle(let lastRelease):
            stage = .recording(startedAt: now, previousRelease: Self.pairing(lastRelease, now))
            return .start
        case .recording:
            // The key is already down: its release ends this recording.
            return nil
        case .locked(let startedAt):
            // Hex leaves the machine dirty until the key is up, so this press's release opens no window.
            return finish(startedAt: startedAt, at: now, lastRelease: nil)
        case .processing(let lastRelease):
            switch pendingPress {
            case nil:
                pendingPress = PendingPress(
                    pressedAt: now, previousRelease: Self.pairing(lastRelease, now), locked: false)
            case let pending? where pending.locked:
                // The press that would end the queued lock: the two net to nothing, and no window opens.
                pendingPress = nil
                stage = .processing(lastRelease: nil)
            default:
                break
            }
            return nil
        }
    }

    mutating func released(at now: ContinuousClock.Instant) -> DictationActivation.Effect? {
        switch stage {
        case .recording(let startedAt, let previousRelease):
            if Self.pairing(previousRelease, now) != nil {
                stage = .locked(startedAt: startedAt)
                return nil
            }
            return finish(startedAt: startedAt, at: now, lastRelease: now)
        case .processing:
            guard let pending = pendingPress, !pending.locked else { return nil }
            if Self.pairing(pending.previousRelease, now) != nil {
                pendingPress?.locked = true
            } else {
                // A tap or a hold that ended before the drain has nothing left to start, the coordinator's rule;
                // its release still opens the window, as any finished recording's does in Hex.
                pendingPress = nil
                stage = .processing(lastRelease: now)
            }
            return nil
        case .idle, .locked:
            return nil
        }
    }

    mutating func processingFinished() -> DictationActivation.Effect? {
        guard case .processing(let lastRelease) = stage else { return nil }
        guard let pending = pendingPress else {
            stage = .idle(lastRelease: lastRelease)
            return nil
        }
        pendingPress = nil
        stage = pending.locked
            ? .locked(startedAt: pending.pressedAt)
            : .recording(startedAt: pending.pressedAt, previousRelease: pending.previousRelease)
        return .start
    }

    /// A refused start leaves the machine idle, as Hex's `suspend` does.
    mutating func startResult(started: Bool) {
        if !started, isRecording { stage = .idle(lastRelease: nil) }
    }

    /// Ends a recording at once; a transcription under way still finishes, without the press remembered for it.
    mutating func cancel() {
        pendingPress = nil
        if case .processing = stage {
            stage = .processing(lastRelease: nil)
        } else {
            stage = .idle(lastRelease: nil)
        }
    }

    /// A recording ended `now`: transcribed when it outlasted the hold threshold, otherwise a tap to discard.
    private mutating func finish(
        startedAt: ContinuousClock.Instant, at now: ContinuousClock.Instant, lastRelease: ContinuousClock.Instant?
    ) -> DictationActivation.Effect {
        if startedAt.duration(to: now) >= Self.holdThreshold {
            stage = .processing(lastRelease: lastRelease)
            return .stop
        }
        stage = .idle(lastRelease: lastRelease)
        return .discard
    }
}
