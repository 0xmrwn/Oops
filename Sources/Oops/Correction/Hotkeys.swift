import AppKit
import Carbon
import OopsCore

typealias HotkeyPhase = HotkeyRouter<ShortcutSettings.Action>.Phase
/// When a hotkey event happened, on the clock microphone timestamps share and on the one activation timing uses.
typealias HotkeyInstant = (capture: CaptureInstant, clock: ContinuousClock.Instant)

/// Registers only the configured chords; no always-on typing event tap. Carbon hotkeys keep firing while
/// another app holds secure keyboard input, where an event tap stops seeing key presses.
@MainActor final class HyperShortcuts {
    private var handler: EventHandlerRef?
    private var refs: [EventHotKeyRef] = []
    /// Escape while a recording runs, apart from the actions: it comes and goes without touching them.
    private var cancelRefs: [EventHotKeyRef] = []
    /// The modifier sets Escape is registered with, kept across re-registration.
    private var cancelChords: [UInt32] = []
    /// Escape's identity, beyond any action's.
    nonisolated static let cancelIdentity: UInt32 = 0xE5C
    /// Told when Escape is pressed while it is registered.
    var cancel: (() -> Void)?
    private var layoutObserver: NSObjectProtocol?
    /// Each action under its own hotkey identity, so the handler knows which one fired.
    private var router = HotkeyRouter(ShortcutSettings.Action.allCases)
    /// Told which action's chord went down or came up, and when: taken as the event arrives, before the hop
    /// to the main thread. A held chord tells its press once.
    var invoke: ((ShortcutSettings.Action, HotkeyPhase, HotkeyInstant) -> Void)?
    var registrationFailed: ((String) -> Void)?
    func register() throws {
        // Keep observing even when the current layout cannot bind the shortcuts.
        if layoutObserver == nil {
            layoutObserver = DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    do { try self.register() } catch { self.registrationFailed?(error.localizedDescription) }
                }
            }
        }
        clearRegistrations()
        let settings = ShortcutSettings.shared
        settings.hotkeys = self
        // Fix runs on the press, so the draft is read while the keys are still down; anything that
        // types waits for them to come up. A held chord repeats its press: one press told per hold.
        var specs = [kEventHotKeyPressed, kEventHotKeyReleased].map { EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32($0)) }
        let context = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetEventDispatcherTarget(), { _, event, userData in
            guard let event, let userData else { return noErr }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed), identity = id.id
            let instant: HotkeyInstant = (CaptureInstant.now(), ContinuousClock.now)
            let owner = Unmanaged<HyperShortcuts>.fromOpaque(userData).takeUnretainedValue()
            if identity == HyperShortcuts.cancelIdentity {
                if pressed { DispatchQueue.main.async { owner.cancel?() } }
                return noErr
            }
            KeyboardGate.heldShortcuts.withLock { held in
                if pressed { held.insert(identity) } else { held.remove(identity) }
            }
            DispatchQueue.main.async { owner.deliver(identity: identity, pressed: pressed, at: instant) }
            return noErr
        }, specs.count, &specs, context, &handler)
        guard status == noErr else { throw CorrectionError.message("Could not register keyboard shortcut handler.") }
        var problems: [String] = []
        for action in ShortcutSettings.Action.allCases {
            guard let identity = router.identity(of: action) else { continue }
            let shortcut: Shortcut
            switch settings.registration(action) {
            case .chord(let chord): shortcut = chord
            case .off: continue
            case .noDefault:
                failed.insert(action)
                problems.append("This keyboard layout has no W key for the default shortcut. Choose one in Settings.")
                continue
            }
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers,
                                            EventHotKeyID(signature: 0x53545854, id: identity), GetEventDispatcherTarget(), 0, &ref)
            if status == noErr, let ref { refs.append(ref) } else {
                failed.insert(action)
                problems.append(Self.taken(shortcut))
            }
        }
        registerCancel()
        if !problems.isEmpty { throw CorrectionError.message(problems.joined(separator: " ")) }
    }

    /// Registers Escape with each of `chords` (Carbon modifier sets), replacing the last ones; none removes it.
    /// Only while the shortcuts are registered: `register()` brings back the chords last asked for.
    func armCancel(_ chords: [UInt32]) {
        cancelChords = chords
        unregisterCancel()
        if handler != nil { registerCancel() }
    }

    private func registerCancel() {
        for modifiers in cancelChords {
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(DictationEscape.keyCode, modifiers, EventHotKeyID(signature: 0x53545854, id: Self.cancelIdentity),
                                             GetEventDispatcherTarget(), 0, &ref)
            if status == noErr, let ref { cancelRefs.append(ref) }
        }
    }

    private func unregisterCancel() {
        cancelRefs.forEach { UnregisterEventHotKey($0) }
        cancelRefs = []
    }
    /// One hotkey event, on the main thread: the action it belongs to, pressed or released.
    private func deliver(identity: UInt32, pressed: Bool, at instant: HotkeyInstant) {
        guard let event = router.route(identity: identity, pressed: pressed) else { return }
        let settings = ShortcutSettings.shared
        switch event.phase {
        case .pressed: settings.down = event.action
        case .released: if settings.down == event.action { settings.down = nil }
        }
        invoke?(event.action, event.phase, instant)
    }
    /// Actions whose shortcut did not register in the last `register()`.
    private(set) var failed: Set<ShortcutSettings.Action> = []
    static func taken(_ shortcut: Shortcut) -> String {
        "\(shortcut.label) is already in use by another app. Choose another shortcut, or free that one."
    }
    /// Stops the shortcuts until the next `register()`.
    func suspend() { clearRegistrations() }
    func unregister() {
        if let layoutObserver { DistributedNotificationCenter.default().removeObserver(layoutObserver) }; layoutObserver = nil
        clearRegistrations()
    }
    private func clearRegistrations() {
        refs.forEach { UnregisterEventHotKey($0) }; refs = []; failed = []; unregisterCancel()
        ShortcutSettings.shared.down = nil; let cut = router.reset()
        KeyboardGate.heldShortcuts.withLock { $0 = [] }
        if let handler { RemoveEventHandler(handler) }; handler = nil
        // A chord that was down loses its release with its registration: told here, so nothing waits on it.
        let now: HotkeyInstant = (CaptureInstant.now(), ContinuousClock.now)
        cut.forEach { invoke?($0.action, $0.phase, now) }
    }
}
