import Foundation

// Hex's `hotkey_pre_roll` (github.com/anomalyco/hex, `src/dictation.rs` at v3.4.0, 8766d096; MIT, Copyright (c)
// 2026 Christopher Langton), read against Oops's "While dictating" setting.

public extension DictationAudioSettings {
    /// How much audio a shortcut capture keeps from before its press. Muting, pausing or lowering other audio
    /// while dictating takes effect only after the press, so the audio before it holds whatever was playing:
    /// those captures keep none. Doing nothing keeps `preRoll`.
    static func hotkeyPreRoll(_ behavior: DictationWhileDictating) -> Duration {
        switch behavior {
        case .mute, .pauseMedia, .lowerAudio: .zero
        case .nothing: preRoll
        }
    }

    /// The pre-roll a press starts with: none unless the microphone is kept ready, as one opened on the press
    /// holds nothing from before it; Hex's otherwise.
    static func pressPreRoll(_ defaults: UserDefaults = .standard) -> Duration {
        keepReady(defaults) ? hotkeyPreRoll(whileDictating(defaults)) : .zero
    }
}
