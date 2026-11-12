import AppKit
import Carbon
import OopsCore

typealias HotkeyPhase = HotkeyRouter<ShortcutSettings.Action>.Phase

/// Registers only the configured chords; no always-on typing event tap.
@MainActor final class HyperShortcuts {
    private var handler: EventHandlerRef?
    private var refs: [EventHotKeyRef] = []
    private var layoutObserver: NSObjectProtocol?
    /// Each action under its own hotkey identity, so the handler knows which one fired.
    private var router = HotkeyRouter(ShortcutSettings.Action.allCases)
    /// Told which action's chord went down or came up. A held chord tells its press once.
    var invoke: ((ShortcutSettings.Action, HotkeyPhase) -> Void)?
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
            let owner = Unmanaged<HyperShortcuts>.fromOpaque(userData).takeUnretainedValue()
            KeyboardGate.heldShortcuts.withLock { held in
                if pressed { held.insert(identity) } else { held.remove(identity) }
            }
            DispatchQueue.main.async { owner.deliver(identity: identity, pressed: pressed) }
            return noErr
        }, specs.count, &specs, context, &handler)
        guard status == noErr else { throw CorrectionError.message("Could not register keyboard shortcut handler.") }
        var problems: [String] = []
        for action in ShortcutSettings.Action.allCases {
            guard let shortcut = settings.shortcut(action), let identity = router.identity(of: action) else {
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
        if !problems.isEmpty { throw CorrectionError.message(problems.joined(separator: " ")) }
    }
    /// One hotkey event, on the main thread: the action it belongs to, pressed or released.
    private func deliver(identity: UInt32, pressed: Bool) {
        guard let event = router.route(identity: identity, pressed: pressed) else { return }
        let settings = ShortcutSettings.shared
        switch event.phase {
        case .pressed: settings.down = event.action
        case .released: if settings.down == event.action { settings.down = nil }
        }
        invoke?(event.action, event.phase)
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
        refs.forEach { UnregisterEventHotKey($0) }; refs = []; failed = []
        ShortcutSettings.shared.down = nil; router.reset()
        KeyboardGate.heldShortcuts.withLock { $0 = [] }
        if let handler { RemoveEventHandler(handler) }; handler = nil
    }
}
