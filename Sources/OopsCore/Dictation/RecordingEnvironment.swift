import Foundation
import Synchronization

// A port of Hex's recording environment at v3.4.0 (MIT, github.com/anomalyco/hex):
// `src/audio/recording_environment.rs`, without its idle-sleep prevention, its browser pause and its "only on
// speakers" lab. See THIRD_PARTY_NOTICES.md.

/// One thing the environment changes while a session wants it. Each is held from the first session that wants it
/// until the last one ends, so overlapping sessions with different choices compose and none restores what another
/// still needs.
public enum RecordingEnvironmentEffect: Int, CaseIterable, Sendable {
    /// Restoration order: output is audible again before a session's callback, and resuming media (AppleScript)
    /// never delays it.
    case mute, duck, pause
}

extension DictationWhileDictating {
    func wants(_ effect: RecordingEnvironmentEffect) -> Bool {
        switch effect {
        case .mute: self == .mute
        case .duck: self == .lowerAudio
        case .pause: self == .pauseMedia
        }
    }
}

/// What the environment holds for one effect until it is restored.
public protocol RecordingEnvironmentHold: AnyObject {
    func restore()
}

/// Owns every held effect on one serial queue: `hold` changes the environment for one effect, and what it returns
/// restores it. Restoring may block that queue (a volume easing back), never the caller.
public final class RecordingEnvironmentController: Sendable {
    private let queue = DispatchQueue(label: "dev.0xmrwn.oops.recording-environment")
    private let state: State

    public init(hold: @escaping @Sendable (RecordingEnvironmentEffect) -> (any RecordingEnvironmentHold)?) {
        state = State(hold: hold)
    }

    /// A dictation's session: applies `audio` ("While dictating") until the session ends.
    public func begin(_ audio: DictationWhileDictating) -> RecordingEnvironmentSession {
        let state = state
        queue.async { state.start(audio) }
        return RecordingEnvironmentSession(controller: self, audio: audio)
    }

    fileprivate func stop(_ audio: DictationWhileDictating, then: (@Sendable () -> Void)?) {
        let state = state
        queue.async { state.stop(audio, then: then) }
    }

    /// Waits, up to `timeout`, for every session already ended to restore output and media. Quitting calls this,
    /// since the process ending would otherwise leave the output muted or lowered.
    public func waitUntilRestored(timeout: Duration) -> Bool {
        let restored = DispatchSemaphore(value: 0)
        queue.async { restored.signal() }
        let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        return restored.wait(timeout: .now() + seconds) == .success
    }

    /// Returns once every command sent before it was handled.
    func settle() { queue.sync {} }

    /// Confined to the queue.
    private final class State: @unchecked Sendable {
        let hold: @Sendable (RecordingEnvironmentEffect) -> (any RecordingEnvironmentHold)?
        var sessions = [Int](repeating: 0, count: RecordingEnvironmentEffect.allCases.count)
        var held = [any RecordingEnvironmentHold?](repeating: nil, count: RecordingEnvironmentEffect.allCases.count)

        init(hold: @escaping @Sendable (RecordingEnvironmentEffect) -> (any RecordingEnvironmentHold)?) { self.hold = hold }

        func start(_ wanted: DictationWhileDictating) {
            for effect in RecordingEnvironmentEffect.allCases where wanted.wants(effect) {
                sessions[effect.rawValue] += 1
                if sessions[effect.rawValue] == 1 { held[effect.rawValue] = hold(effect) }
            }
        }

        func stop(_ wanted: DictationWhileDictating, then: (@Sendable () -> Void)?) {
            var then = then
            for effect in RecordingEnvironmentEffect.allCases {
                if effect == .pause, let callback = then {
                    then = nil
                    callback()
                }
                guard wanted.wants(effect) else { continue }
                sessions[effect.rawValue] = max(0, sessions[effect.rawValue] - 1)
                if sessions[effect.rawValue] == 0 {
                    held[effect.rawValue]?.restore()
                    held[effect.rawValue] = nil
                }
            }
            then?()
        }
    }
}

/// One dictation's hold on the environment, from the moment it became intentional until it ends.
public final class RecordingEnvironmentSession: Sendable {
    private let controller: RecordingEnvironmentController
    private let audio: DictationWhileDictating
    private let ended = Mutex(false)

    fileprivate init(controller: RecordingEnvironmentController, audio: DictationWhileDictating) {
        self.controller = controller
        self.audio = audio
    }

    /// Ends the session and runs `then` once a muted output is audible again; while another session keeps it
    /// muted, or with paused media, it runs at once. A session ends once: ending it again only runs `then`.
    public func end(then: (@Sendable () -> Void)? = nil) {
        let first = ended.withLock { ended in
            defer { ended = true }
            return !ended
        }
        guard first else { then?(); return }
        controller.stop(audio, then: then)
    }

    /// Returns once every command sent before it was handled.
    func settle() { controller.settle() }

    deinit { end() }
}
