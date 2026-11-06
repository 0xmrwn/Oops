import AppKit
import Carbon
import OSLog
import OopsCore

/// One global shortcut: a key code (layout-independent) and Carbon modifier flags.
struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    static let hyper = UInt32(cmdKey | optionKey | controlKey | shiftKey)
    /// Raycast's mark for Hyper, the nearest thing to a convention: drawn beside the word, never alone.
    static let hyperGlyph = "✦"

    /// ⌃⌥⇧⌘ in the system's order, then the key as the current layout prints it.
    var glyphs: [String] {
        [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")]
            .filter { modifiers & UInt32($0.0) != 0 }.map(\.1) + [Self.keyName(keyCode)]
    }
    /// The four-modifier chord's one key: glyph and word, as the glyph alone isn't known.
    static let hyperKey = hyperGlyph + " Hyper"
    /// The chord as keys to draw: ["✦ Hyper", "W"] for Hyper, otherwise one key per glyph.
    var keys: [String] { modifiers == Self.hyper ? [Self.hyperKey, Self.keyName(keyCode)] : glyphs }
    /// "✦ Hyper-W" for the four-modifier chord, otherwise the glyphs: "⌃⌥W".
    var label: String { modifiers == Self.hyper ? Self.hyperKey + "-" + Self.keyName(keyCode) : glyphs.joined() }
    var spoken: String {
        [(controlKey, "Control"), (optionKey, "Option"), (shiftKey, "Shift"), (cmdKey, "Command")]
            .filter { modifiers & UInt32($0.0) != 0 }.map(\.1).joined(separator: " ") + " " + Self.keyName(keyCode)
    }

    static func modifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbon = 0
        if flags.contains(.control) { carbon |= controlKey }
        if flags.contains(.option) { carbon |= optionKey }
        if flags.contains(.shift) { carbon |= shiftKey }
        if flags.contains(.command) { carbon |= cmdKey }
        return UInt32(carbon)
    }

    /// The chord as a menu item's key equivalent, so the menu draws it right-aligned in glyphs.
    var keyEquivalent: (key: String, modifiers: NSEvent.ModifierFlags)? {
        let key: String
        if let special = Self.menuKeys[keyCode] { key = String(Character(UnicodeScalar(special)!)) }
        else if let character = KeyboardLayout.character(for: keyCode) { key = character.lowercased() }
        else { return nil }
        var flags: NSEvent.ModifierFlags = []
        if modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if modifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        return (key, flags)
    }

    private static let menuKeys: [UInt32: Int] = [
        49: 0x20, 36: 0x0D, 48: 0x09, 51: 0x08, 53: 0x1B, 117: NSDeleteFunctionKey,
        123: NSLeftArrowFunctionKey, 124: NSRightArrowFunctionKey, 125: NSDownArrowFunctionKey, 126: NSUpArrowFunctionKey,
        115: NSHomeFunctionKey, 119: NSEndFunctionKey, 116: NSPageUpFunctionKey, 121: NSPageDownFunctionKey,
        122: NSF1FunctionKey, 120: NSF2FunctionKey, 99: NSF3FunctionKey, 118: NSF4FunctionKey, 96: NSF5FunctionKey,
        97: NSF6FunctionKey, 98: NSF7FunctionKey, 100: NSF8FunctionKey, 101: NSF9FunctionKey, 109: NSF10FunctionKey,
        103: NSF11FunctionKey, 111: NSF12FunctionKey,
    ]

    private static let named: [UInt32: String] = [
        49: "Space", 36: "↩", 48: "⇥", 51: "⌫", 117: "⌦", 53: "⎋", 123: "←", 124: "→", 125: "↓", 126: "↑",
        115: "↖", 119: "↘", 116: "⇞", 121: "⇟", 122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]
    static func keyName(_ keyCode: UInt32) -> String {
        named[keyCode] ?? KeyboardLayout.character(for: keyCode)?.uppercased() ?? "#\(keyCode)"
    }
}

/// The two actions' shortcuts. Fix text defaults to ⌃⌘W wherever the layout puts W; Restore has none
/// until one is recorded. A custom one is stored by key code under `Shortcut.<action>`.
@MainActor @Observable final class ShortcutSettings {
    enum Action: String, CaseIterable {
        case correct, restore
        /// The action's icon everywhere it appears (Settings rows, Try's buttons, stats).
        var symbol: String { self == .correct ? "checkmark.bubble" : "arrow.uturn.backward" }
    }
    static let shared = ShortcutSettings()

    private(set) var custom: [Action: Shortcut] = [:]
    /// The action whose shortcut is being recorded: one at a time.
    var recording: Action?
    /// The action whose chord is down, as the hotkeys report it: a registered chord's key never
    /// reaches the app as a keyDown, and Try it lights it from here.
    fileprivate(set) var down: Action?
    /// Set by the hotkey owner: re-registers both shortcuts, or throws without changing them.
    @ObservationIgnored weak var hotkeys: HyperShortcuts?

    private init() {
        for action in Action.allCases {
            if let data = UserDefaults.standard.data(forKey: key(action)), let shortcut = try? JSONDecoder().decode(Shortcut.self, from: data) {
                custom[action] = shortcut
            }
        }
    }

    func shortcut(_ action: Action) -> Shortcut? { custom[action] ?? defaultShortcut(action) }
    /// ⌃⌘W to fix, a chord most people can press and that apps leave free (D8). Fix text pressed again
    /// restores (D10), so Restore needs no chord of its own unless someone records one.
    func defaultShortcut(_ action: Action) -> Shortcut? {
        guard action == .correct else { return nil }
        return KeyboardLayout.keyCode(for: "w").map { Shortcut(keyCode: $0, modifiers: UInt32(controlKey | cmdKey)) }
    }
    func label(_ action: Action) -> String { shortcut(action)?.label ?? "—" }

    /// Saves a shortcut (nil restores the default, none for Restore) once the system accepts it.
    func set(_ action: Action, _ shortcut: Shortcut?) throws {
        let previous = custom
        if let shortcut, Action.allCases.contains(where: { $0 != action && self.shortcut($0) == shortcut }) {
            throw CorrectionError.message("That shortcut is already used by the other action.")
        }
        custom[action] = shortcut
        // Only this action's outcome decides: the other may still be taken by another app, and
        // that must not block fixing this one.
        try? hotkeys?.register()
        if hotkeys?.failed.contains(action) == true {
            let message = self.shortcut(action).map(HyperShortcuts.taken) ?? "That shortcut can’t be used."
            custom = previous; try? hotkeys?.register()
            throw CorrectionError.message(message)
        }
        persist()
    }

    /// While a shortcut is being recorded the current ones must not fire.
    func pause() { hotkeys?.suspend() }
    func resume() { try? hotkeys?.register() }

    private func persist() {
        for action in Action.allCases {
            if let shortcut = custom[action], let data = try? JSONEncoder().encode(shortcut) {
                UserDefaults.standard.set(data, forKey: key(action))
            } else { UserDefaults.standard.removeObject(forKey: key(action)) }
        }
    }
    private func key(_ action: Action) -> String { "Shortcut." + action.rawValue }
}

/// Registers only the configured chords; no always-on typing event tap.
@MainActor final class HyperShortcuts {
    private var handler: EventHandlerRef?
    private var refs: [EventHotKeyRef] = []
    private var layoutObserver: NSObjectProtocol?
    var invoke: (() -> Void)?
    var revert: (() -> Void)?
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
        // Actions run on the press, so the draft is read while the keys are still down; anything that
        // types waits for them to come up. A held chord repeats its press: one action per press.
        var specs = [kEventHotKeyPressed, kEventHotKeyReleased].map { EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32($0)) }
        let context = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetEventDispatcherTarget(), { _, event, userData in
            guard let event, let userData else { return noErr }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            let owner = Unmanaged<HyperShortcuts>.fromOpaque(userData).takeUnretainedValue()
            KeyboardGate.shortcutHeld.withLock { $0 = pressed }
            DispatchQueue.main.async {
                let action: ShortcutSettings.Action = id.id == 1 ? .correct : .restore
                guard pressed else { ShortcutSettings.shared.down = nil; return }
                guard ShortcutSettings.shared.down != action else { return }
                ShortcutSettings.shared.down = action
                if action == .correct { owner.invoke?() } else { owner.revert?() }
            }
            return noErr
        }, specs.count, &specs, context, &handler)
        guard status == noErr else { throw CorrectionError.message("Could not register keyboard shortcut handler.") }
        // Each action on its own: one taken chord must not take the other down, or Settings could
        // never repair a pair that both collide.
        var problems: [String] = []
        for action in ShortcutSettings.Action.allCases {
            guard let shortcut = settings.shortcut(action) else {
                // Restore unset is its default; only Fix text's default can be missing from a layout.
                if action == .correct {
                    failed.insert(action)
                    problems.append("This keyboard layout has no W key for the default shortcut. Choose one in Settings.")
                }
                continue
            }
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers,
                                            EventHotKeyID(signature: 0x53545854, id: action == .correct ? 1 : 2), GetEventDispatcherTarget(), 0, &ref)
            if status == noErr, let ref { refs.append(ref) } else {
                failed.insert(action)
                problems.append(Self.taken(shortcut))
            }
        }
        if !problems.isEmpty { throw CorrectionError.message(problems.joined(separator: " ")) }
    }
    /// Actions whose shortcut did not register in the last `register()`.
    private(set) var failed: Set<ShortcutSettings.Action> = []
    static func taken(_ shortcut: Shortcut) -> String {
        "\(shortcut.label) is already in use by another app. Choose another shortcut, or free that one."
    }
    /// Stops both shortcuts until the next `register()`.
    func suspend() { clearRegistrations() }
    func unregister() {
        if let layoutObserver { DistributedNotificationCenter.default().removeObserver(layoutObserver) }; layoutObserver = nil
        clearRegistrations()
    }
    private func clearRegistrations() {
        refs.forEach { UnregisterEventHotKey($0) }; refs = []; failed = []
        ShortcutSettings.shared.down = nil
        KeyboardGate.shortcutHeld.withLock { $0 = false }
        if let handler { RemoveEventHandler(handler) }; handler = nil
    }
}

/// Bounded input gate only during the final selection/paste/readback, not inference.
/// Replay physical key/click events afterward so typing cannot land in our temporary selection.
/// The swap asks `isActive` from the Accessibility queue: its state is behind `lock`, and the tap, its
/// source and the watchdog are set in `init` and torn down in `release`, both on the main thread.
final class KeyboardGate: @unchecked Sendable {
    private static let log = Logger(subsystem: "dev.0xmrwn.oops", category: "Keyboard")
    /// Between the shortcut's press and its release, as the hotkey handler reports them.
    static let shortcutHeld = OSAllocatedUnfairLock(initialState: false)
    static func waitForModifierRelease() async throws {
        let blocking: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
        let waits = try await ModifierRelease.wait(shortcutHeld: { shortcutHeld.withLock { $0 } }, isReleased: {
            CGEventSource.flagsState(.combinedSessionState).isDisjoint(with: blocking)
        }, keyboardReleased: {
            CGEventSource.flagsState(.hidSystemState).isDisjoint(with: blocking)
        })
        let stale = CGEventSource.flagsState(.combinedSessionState).intersection(blocking)
        log.info("modifier_release_confirmed waits=\(waits, privacy: .public) stale=\(String(stale.rawValue, radix: 16), privacy: .public)")
    }
    static let marker: Int64 = 0x53545854
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private let lock = NSLock()
    private var held: [CGEvent] = []
    private var released = false
    private var expired = false
    private var watchdog: DispatchWorkItem?
    var isActive: Bool { lock.lock(); defer { lock.unlock() }; return !released && !expired }
    init() throws {
        let kinds: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .scrollWheel]
        let mask = kinds.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                               eventsOfInterest: mask, callback: { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let owner = Unmanaged<KeyboardGate>.fromOpaque(context).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = owner.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            if event.getIntegerValueField(.eventSourceUserData) == KeyboardGate.marker { return Unmanaged.passUnretained(event) }
            owner.lock.lock(); defer { owner.lock.unlock() }
            if owner.released { return Unmanaged.passUnretained(event) }
            if let copy = event.copy() { owner.held.append(copy) }
            return nil
        }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else { throw CorrectionError.message("macOS could not protect the brief text swap. Check the Accessibility permission for Oops.") }
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        // Expiry revokes permission to paste. Only the finished AX operation releases
        // physical input, after its temporary selection has been settled/restored.
        let watchdog = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.expired = true; self.lock.unlock()
        }
        self.watchdog = watchdog
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: watchdog)
    }
    deinit { release() }
    func release() {
        lock.lock()
        guard !released else { lock.unlock(); return }
        released = true; let events = held; held = []; lock.unlock()
        watchdog?.cancel()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        for event in events {
            event.setIntegerValueField(.eventSourceUserData, value: Self.marker)
            event.post(tap: .cgSessionEventTap)
        }
    }
    /// ⌘ plus the key that types `character` in the current layout: keycode 9 is V on QWERTY and
    /// AZERTY but K on Dvorak, and keycode 0 is A on QWERTY but Q, quit, on AZERTY.
    static func postCommand(_ character: Character, shift: Bool = false) {
        postKey(CommandKeys.shared.code(character), flags: shift ? [.maskCommand, .maskShift] : .maskCommand)
    }

    /// Short, printable text through the host's native input path. Longer edits and control
    /// characters keep the clipboard path; Quartz events must not truncate a replacement.
    static func postText(_ text: String) -> Bool {
        let units = Array(text.utf16)
        guard !units.isEmpty, units.count <= 20, !text.contains(where: \.isNewline),
              !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { return false }
        for event in [down, up] {
            event.flags = []
            event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            event.setIntegerValueField(.eventSourceUserData, value: marker)
            event.post(tap: .cgSessionEventTap)
        }
        return true
    }

    static func postKey(_ code: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .privateState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
            event?.flags = flags
            event?.setIntegerValueField(.eventSourceUserData, value: marker)
            event?.post(tap: .cgSessionEventTap)
        }
    }
}

/// The keys Oops presses with ⌘, as the current layout places them. The input source APIs belong to
/// the main thread, so the codes are worked out there at launch and on every layout change, and read
/// from any thread. A layout that types none of them (Cyrillic, Greek) uses the ANSI keys, as macOS
/// does for its own shortcuts.
final class CommandKeys: @unchecked Sendable {
    static let shared = CommandKeys()
    private static let ansi: [Character: CGKeyCode] = ["a": 0, "c": 8, "v": 9, "n": 45, "z": 6]
    private let lock = NSLock()
    private var codes: [Character: CGKeyCode] = [:]

    func code(_ character: Character) -> CGKeyCode {
        lock.withLock { codes[character] } ?? Self.ansi[character] ?? 0
    }

    @MainActor func observe() {
        refresh()
        DistributedNotificationCenter.default().addObserver(forName: .init(kTISNotifySelectedKeyboardInputSourceChanged as String),
                                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    @MainActor private func refresh() {
        var found: [Character: CGKeyCode] = [:]
        for character in Self.ansi.keys {
            if let code = KeyboardLayout.keyCode(for: String(character), command: true) { found[character] = CGKeyCode(code) }
        }
        lock.withLock { codes = found }
    }
}
