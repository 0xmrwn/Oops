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

/// The shortcuts. Fix text defaults to ⌃⌘W wherever the layout puts W; pressed again it restores (D10).
/// Dictate and Paste last dictation have no default: without a shortcut they are off. A custom one is stored
/// by key code under `Shortcut.<action>`.
@MainActor @Observable final class ShortcutSettings {
    enum Action: String, CaseIterable {
        case correct
        case dictate
        /// One dictation cleaned up whatever Clean up says; no default, so no hotkey until one is chosen.
        case dictateAndCleanUp
        case pasteLast
        /// The action's icon everywhere it appears (Settings rows, Try's buttons, stats).
        var symbol: String {
            switch self {
            case .correct: "checkmark.bubble"
            case .dictate: SettingsTab.dictate.symbol
            case .dictateAndCleanUp: "wand.and.sparkles"
            case .pasteLast: "doc.on.clipboard"
            }
        }
        /// The action's name in Settings.
        var title: String {
            switch self {
            case .correct: "Fix text"
            case .dictate: "Dictate"
            case .dictateAndCleanUp: "Dictate and clean up"
            case .pasteLast: "Paste last dictation"
            }
        }
        /// The Settings tab the action belongs to.
        var tab: SettingsTab {
            switch self {
            case .correct: .fix
            case .dictate, .dictateAndCleanUp, .pasteLast: .dictate
            }
        }
        /// Whether the shortcut is its feature's switch, which General's Turn on records.
        var isSwitch: Bool { self == .correct || self == .dictate }
    }

    /// What `register()` does with an action: binds its chord, leaves it off, or reports that its
    /// default can't be had on this layout.
    enum Registration: Equatable {
        case chord(Shortcut)
        case off
        case noDefault
    }
    static let shared = ShortcutSettings()

    private(set) var custom: [Action: Shortcut] = [:]
    /// The action whose chord is down, as the hotkeys report it: a registered chord's key never
    /// reaches the app as a keyDown, and Try it lights it from here.
    var down: Action?
    /// Set by the hotkey owner: re-registers the shortcuts, or throws without changing them.
    @ObservationIgnored weak var hotkeys: HyperShortcuts?

    private init() {
        // Restore had a shortcut of its own until Fix text pressed again took its place (D10): one
        // recorded then is dropped, so it never fires or blocks a chord again.
        UserDefaults.standard.removeObject(forKey: "Shortcut.restore")
        for action in Action.allCases {
            if let data = UserDefaults.standard.data(forKey: key(action)), let shortcut = try? JSONDecoder().decode(Shortcut.self, from: data) {
                custom[action] = shortcut
            }
        }
    }

    func shortcut(_ action: Action) -> Shortcut? { custom[action] ?? defaultShortcut(action) }
    func defaultShortcut(_ action: Action) -> Shortcut? { Self.defaultShortcut(action, w: KeyboardLayout.keyCode(for: "w")) }
    /// ⌃⌘W to fix, a chord most people can press and that apps leave free (D8), when the layout has a W
    /// (`w`, its key code). Dictate has none.
    static func defaultShortcut(_ action: Action, w: UInt32?) -> Shortcut? {
        guard action == .correct else { return nil }
        return w.map { Shortcut(keyCode: $0, modifiers: UInt32(controlKey | cmdKey)) }
    }
    func label(_ action: Action) -> String { shortcut(action)?.label ?? "—" }

    func registration(_ action: Action) -> Registration {
        // Paste last dictation goes off with Dictate, as its menu item does: only a feature's own shortcut
        // stands without it.
        let dictation = DebugFlags.dictation && (action.isSwitch || shortcut(.dictate) != nil)
        return Self.registration(action, shortcut: shortcut(action), dictation: dictation)
    }
    /// Dictate's shortcuts only while dictation is switched on. An action with no shortcut is off, which is no
    /// failure; only Fix, whose default is missing from this layout, has something to report.
    static func registration(_ action: Action, shortcut: Shortcut?, dictation: Bool) -> Registration {
        if action != .correct, !dictation { return .off }
        if let shortcut { return .chord(shortcut) }
        return action == .correct ? .noDefault : .off
    }

    /// The other action already bound to `shortcut`, among the ones that register: two actions on one
    /// chord would leave one of them dead, whatever the system says.
    static func clash(_ action: Action, _ shortcut: Shortcut, with shortcuts: [Action: Shortcut], dictation: Bool) -> Action? {
        Action.allCases.first { other in
            other != action && shortcuts[other] == shortcut
                && registration(other, shortcut: shortcuts[other], dictation: dictation) != .off
        }
    }

    /// Saves a shortcut (nil restores the default, or turns off an action that has none) once the system
    /// accepts it.
    func set(_ action: Action, _ shortcut: Shortcut?) throws {
        if let chosen = shortcut ?? defaultShortcut(action) {
            let others = Dictionary(uniqueKeysWithValues: Action.allCases.compactMap { other in self.shortcut(other).map { (other, $0) } })
            if let other = Self.clash(action, chosen, with: others, dictation: DebugFlags.dictation) {
                throw CorrectionError.message("\(chosen.label) is already in use by \(other.title). Choose another shortcut.")
            }
        }
        let previous = custom
        custom[action] = shortcut
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

/// Bounded input gate only during the final selection/paste/readback, not inference.
/// Replay physical key/click events afterward so typing cannot land in our temporary selection.
/// The swap asks `isActive` from the Accessibility queue: its state is behind `lock`, and the tap, its
/// source and the watchdog are set in `init` and torn down in `release`, both on the main thread.
final class KeyboardGate: @unchecked Sendable {
    private static let log = Logger(subsystem: "dev.0xmrwn.oops", category: "Keyboard")
    /// The hotkeys between their press and their release, by identity, as the hotkey handler reports them.
    static let heldShortcuts = OSAllocatedUnfairLock(initialState: Set<UInt32>())
    static func waitForModifierRelease() async throws {
        let blocking: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
        let waits = try await ModifierRelease.wait(shortcutHeld: { heldShortcuts.withLock { !$0.isEmpty } }, isReleased: {
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
        guard let tap else { throw CorrectionError.message("macOS could not protect the brief text swap. Check that Oops is allowed in \(AccessibilityPermission.paneName).") }
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
