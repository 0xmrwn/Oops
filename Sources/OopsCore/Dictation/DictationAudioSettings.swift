import Foundation

/// What happens to the Mac's sound while a dictation records. The raw values are what Settings stores.
public enum DictationWhileDictating: String, CaseIterable, Sendable {
    case nothing
    /// The output is muted.
    case mute
    /// Players that are playing are paused.
    case pauseMedia
    /// The output volume is lowered to a share of what it was.
    case lowerAudio
}

/// Dictate's microphone and audio settings: where each is kept, and what it is until one is chosen.
public enum DictationAudioSettings {
    /// Whether the microphone stays open while Dictate has a shortcut, keeping the audio from just before a press.
    public static let keepReadyKey = "DictationKeepMicrophoneReady"
    /// Whether a Bluetooth system default is passed over for the built-in or a wired microphone.
    public static let avoidBluetoothKey = "DictationAvoidBluetooth"
    /// The microphone picked by name, as its device UID; absent is the system default.
    public static let microphoneKey = "DictationMicrophone"
    public static let whileDictatingKey = "DictationWhileDictating"
    /// Lower audio's level, as a share of the volume before the recording.
    public static let lowerLevelKey = "DictationLowerAudioLevel"

    /// The audio kept from before a press while the microphone is ready, as Hex's `PRE_ROLL_DURATION`.
    public static let preRoll: Duration = .milliseconds(450)
    public static let defaultLowerLevel = 0.2

    public static func keepReady(_ defaults: UserDefaults = .standard) -> Bool { defaults.bool(forKey: keepReadyKey) }

    /// On until switched off.
    public static func avoidBluetooth(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: avoidBluetoothKey) as? Bool ?? true
    }

    /// The picked microphone's UID, or nil for the system default.
    public static func microphone(_ defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: microphoneKey).flatMap { $0.isEmpty ? nil : $0 }
    }

    public static func whileDictating(_ defaults: UserDefaults = .standard) -> DictationWhileDictating {
        defaults.string(forKey: whileDictatingKey).flatMap(DictationWhileDictating.init(rawValue:)) ?? .nothing
    }

    /// Lower audio's level, between 0 and 1.
    public static func lowerLevel(_ defaults: UserDefaults = .standard) -> Double {
        min(max(defaults.object(forKey: lowerLevelKey) as? Double ?? defaultLowerLevel, 0), 1)
    }
}
