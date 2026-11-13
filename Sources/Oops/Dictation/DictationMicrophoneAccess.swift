import AVFoundation

/// Whether Oops may use the microphone. Reading it never asks; only the asking function below shows the
/// system prompt.
enum DictationMicrophoneAccess: Equatable, Sendable {
    case granted
    case denied
    /// Never asked: the first use would prompt. Settings asks as Dictate gets its shortcut, and a press that
    /// still finds it so asks then, recording nothing.
    case undetermined

    static var current: DictationMicrophoneAccess {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: .granted
        case .undetermined: .undetermined
        default: .denied
        }
    }

    /// Asks for microphone access, with the system prompt when it was never asked. Settings calls it, and a
    /// dictation whose press finds access never asked; a recording never does.
    static func requestAccess() async -> Bool { await AVAudioApplication.requestRecordPermission() }
}
