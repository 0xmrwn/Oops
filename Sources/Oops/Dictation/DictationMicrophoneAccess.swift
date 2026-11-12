import AVFoundation

/// Whether Oops may use the microphone. Reading it never asks; only the asking function below shows the
/// system prompt.
enum DictationMicrophoneAccess: Equatable, Sendable {
    case granted
    case denied
    /// Never asked: the first use would prompt, so dictation waits for Settings to ask.
    case undetermined

    static var current: DictationMicrophoneAccess {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: .granted
        case .undetermined: .undetermined
        default: .denied
        }
    }

    /// Asks for microphone access, with the system prompt when it was never asked. For Settings only:
    /// dictation itself never asks.
    static func requestAccess() async -> Bool { await AVAudioApplication.requestRecordPermission() }
}
