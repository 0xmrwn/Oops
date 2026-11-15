import Foundation
import OopsCore

/// Keeps the recorder's microphone open while "Keep the microphone ready" is on and Dictate has a shortcut,
/// from launch and as either changes. Both live in the user defaults, so a change to either is a defaults change.
@MainActor final class DictationReadiness {
    private let recorder: DictationRecorder
    private let wanted: @MainActor () -> Bool
    private var observer: any NSObjectProtocol?
    private var applied: Bool?
    /// The last change handed to the recorder: each waits for the one before, so a quick on-off lands in order.
    private var handing: Task<Void, Never>?

    init(recorder: DictationRecorder, defaults: UserDefaults = .standard,
         wanted: @escaping @MainActor () -> Bool = { DictationAudioSettings.keepReady() && ShortcutSettings.shared.custom[.dictate] != nil }) {
        self.recorder = recorder; self.wanted = wanted
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: defaults, queue: nil) { [weak self] _ in
            Task { @MainActor in self?.apply() }
        }
        apply()
    }

    isolated deinit { observer.map(NotificationCenter.default.removeObserver) }

    /// Tells the recorder when the wish changes; every defaults change lands here, most of them unrelated.
    func apply() {
        let ready = wanted()
        guard ready != applied else { return }
        applied = ready
        let recorder = recorder, previous = handing
        handing = Task {
            await previous?.value
            await recorder.keepReady(ready)
        }
    }

    /// Waits until the recorder has heard every change so far.
    func settled() async { await handing?.value }
}
