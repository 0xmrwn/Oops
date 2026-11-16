import CoreAudio
import Foundation
import IOKit
import OopsCore
import Synchronization

/// Counts the changes that can move which microphone a dictation records from: the default input, the list of
/// inputs, the lid opening or closing, and Dictate's microphone settings. The microphone compares the count with
/// the one its input was chosen at (Hex's `input_route_generation`); Settings refreshes the inputs it names.
final class MicrophoneWatch: Sendable {
    static let shared = MicrophoneWatch()

    private let count = Atomic<UInt64>(0)
    private let handlers = Mutex<[UUID: @Sendable () -> Void]>([:])
    private let settings = Mutex<(avoidBluetooth: Bool, microphone: String?)?>(nil)
    private let queue = DispatchQueue(label: "oops.microphone.watch")
    private let started = Mutex(false)

    var generation: UInt64 { count.load(ordering: .acquiring) }

    /// Calls `handler` on a background queue after each change, until `stop` with the returned token.
    func observe(_ handler: @escaping @Sendable () -> Void) -> UUID {
        start()
        let token = UUID()
        handlers.withLock { $0[token] = handler }
        return token
    }

    func stop(_ token: UUID) { handlers.withLock { $0[token] = nil } }

    private func changed() {
        count.add(1, ordering: .acquiringAndReleasing)
        for handler in handlers.withLock({ Array($0.values) }) { handler() }
    }

    /// Registers the listeners once. CoreAudio and IOKit call back on this queue, never the audio thread.
    private func start() {
        guard started.withLock({ started in
            defer { started = true }
            return !started
        }) else { return }
        for selector in [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDevices] {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue) { _, _ in self.changed() }
        }
        watchLid()
        settings.withLock { $0 = Self.currentSettings() }
        // The watch lives for the process.
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: nil) { _ in
            self.queue.async { self.settingsMayHaveChanged() }
        }
    }

    /// UserDefaults says only that something changed: only the two settings that choose the microphone count.
    private func settingsMayHaveChanged() {
        let now = Self.currentSettings()
        let changed = settings.withLock { last in
            defer { last = now }
            return last.map { $0.avoidBluetooth != now.avoidBluetooth || $0.microphone != now.microphone } ?? true
        }
        if changed { self.changed() }
    }

    private static func currentSettings() -> (avoidBluetooth: Bool, microphone: String?) {
        (DictationAudioSettings.avoidBluetooth(), DictationAudioSettings.microphone())
    }

    /// Closing the lid switches the built-in microphone off without changing CoreAudio's devices or default input.
    private func watchLid() {
        let root = MicrophoneDevices.rootDomain
        guard root != 0, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        IONotificationPortSetDispatchQueue(port, queue)
        var notification: io_object_t = 0
        // The port and notification live for the process, and the callback only reads the shared watch.
        IOServiceAddInterestNotification(port, root, kIOGeneralInterest, { _, _, message, _ in
            // `kIOPMMessageClamshellStateChange`: `iokit_family_msg(sub_iokit_powermanagement, 0x100)`.
            if message == 0xE003_4100 { MicrophoneWatch.shared.changed() }
        }, nil, &notification)
    }
}
