import AppKit
import OopsCore

/// What the Mac's sound does while a dictation records ("While dictating"), applied only once the recording is
/// intentional and undone when it ends.
///
/// Intentional is Hex's rule: the recording still runs at its press plus the hold threshold. A tap that ends sooner
/// (a discarded tap, a short push-to-talk) never touches the output; a latched or held recording does, even when
/// its microphone took longer to open. The choice is read when the recording becomes intentional.
@MainActor final class DictationRecordingEnvironment {
    private let controller: RecordingEnvironmentController
    private let choice: @MainActor () -> DictationWhileDictating
    private var intent: Task<Void, Never>?
    private var session: RecordingEnvironmentSession?

    init(controller: RecordingEnvironmentController = .native(),
         choice: @escaping @MainActor () -> DictationWhileDictating = { DictationAudioSettings.whileDictating() }) {
        self.controller = controller
        self.choice = choice
        // A normal quit restores what a recording under way changed; the process ending would leave it.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.restoreBeforeQuit() }
        }
    }

    /// A recording began for the press at `pressedAt`.
    func recordingStarted(pressedAt: ContinuousClock.Instant) {
        recordingEnded()
        let due = pressedAt + DictationActivation.holdThreshold
        intent = Task { [weak self] in
            try? await Task.sleep(until: due, clock: .continuous)
            guard !Task.isCancelled, let self else { return }
            intent = nil
            let choice = choice()
            if choice != .nothing { session = controller.begin(choice) }
        }
    }

    /// The recording stopped, was discarded or cancelled: what it changed is restored, and a recording not yet
    /// intentional never changes anything.
    func recordingEnded() {
        intent?.cancel()
        intent = nil
        session?.end()
        session = nil
    }

    /// Ends the recording's hold and waits, up to `timeout`, for the output and media to be restored.
    func restoreBeforeQuit(timeout: Duration = .seconds(2)) -> Bool {
        recordingEnded()
        return controller.waitUntilRestored(timeout: timeout)
    }
}
