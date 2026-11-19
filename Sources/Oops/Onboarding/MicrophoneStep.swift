import AppKit

/// The microphone, asked for the moment Dictate's shortcut is accepted in the Shortcut step: that is when Dictate
/// comes on. Someone who leaves Dictate out never sees the prompt.
@MainActor @Observable final class MicrophoneStep {
    enum State: Equatable { case unasked, asking, granted, refused }
    private(set) var state = State.unasked
    @ObservationIgnored private let saves: Bool

    init(saves: Bool) { self.saves = saves }

    /// Asks once. A run that saves nothing never shows the system's prompt: it plays the answer
    /// `-DebugMicrophoneAccess` names. A build without the speech engine has nothing to ask for.
    func ask() {
        guard state == .unasked else { return }
        guard saves, DictationEngineProvider.engine() != nil else {
            state = DebugFlags.microphoneAccess == "denied" ? .refused : .granted
            return
        }
        switch DictationMicrophoneAccess.current {
        case .granted: state = .granted
        case .denied: state = .refused
        case .undetermined:
            state = .asking
            Task { state = await DictationMicrophoneAccess.requestAccess() ? .granted : .refused }
        }
    }

    /// Back from System Settings: access given there is seen without another press.
    func recheck() {
        if saves, state == .refused, DictationMicrophoneAccess.current == .granted { state = .granted }
    }

    /// The Microphone list in Privacy & Security: once refused, the system won't ask again.
    static func openSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Microphone") else { return }
        NSWorkspace.shared.open(url)
    }
}
