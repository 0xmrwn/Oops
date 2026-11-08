import AppKit
import Carbon
import OopsCore
import SwiftUI

/// Onboarding's Shortcut step: large keycaps that light up as their keys are held. Pressing the
/// shortcut Fix text uses (the app's default, `ShortcutSettings.defaultShortcut`, unless one was
/// recorded) accepts it; Change records another chord, Hyper included.
///
/// The global hotkeys are paused while the window is key, so the shortcut reaches the step instead of
/// correcting. A recorded chord is saved as Settings saves it, once the system accepts it. Without
/// `preferences` (a `--hello-only` run beside a real Oops) nothing is saved.
@MainActor @Observable final class ShortcutStep {
    enum Phase: Equatable { case waiting, recording, accepted }
    struct Cap: Identifiable, Equatable {
        let id: Int
        let label: String
        var lit: Double
        var down = false
        /// Hyper's four modifiers, each lit while it is held.
        var parts: [Cap] = []
    }

    /// The onboarding window's identifier: the step only listens to keys pressed there.
    static let window = NSUserInterfaceItemIdentifier("onboarding")

    private(set) var shortcut = ShortcutSettings.shared.shortcut(.correct)
    private(set) var phase = Phase.waiting
    private(set) var error: String?
    /// Modifiers and the key held right now.
    private(set) var held: NSEvent.ModifierFlags = []
    private(set) var key: UInt16?
    /// The flash every cap takes when the shortcut is accepted, settling to a soft glow.
    private(set) var glow = 0.0
    /// The drop's eyes, in `DashEyes` units: on the keys, then a check once the shortcut is pressed.
    private(set) var look = CGSize(width: 0, height: 0.7)
    private(set) var lid = 0.0
    private(set) var check = 0.0

    @ObservationIgnored let saves: Bool
    @ObservationIgnored private var sounds: HelloSounds?
    @ObservationIgnored private var monitor: Any?
    /// Try it's listening: the keys light, nothing is accepted, and `heard` gets the shortcut.
    @ObservationIgnored private var mirroring = false
    @ObservationIgnored private var heard: (() -> Bool)?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// Whether the shortcut had been pressed before Change: cancelling goes back to that.
    @ObservationIgnored private var acceptedBeforeChange = false

    init(saves: Bool) { self.saves = saves }

    /// ⌃⌥⇧⌘ in the system's order.
    private static let modifiers: [(flag: NSEvent.ModifierFlags, glyph: String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
    private static let all: NSEvent.ModifierFlags = [.control, .option, .shift, .command]

    // MARK: Keycaps

    /// The keys with the accepted glow.
    var caps: [Cap] {
        keys.map { var cap = $0; cap.lit = max(cap.lit, glow); cap.parts = cap.parts.map { var part = $0; part.lit = max(part.lit, glow); return part }; return cap }
    }

    /// The shortcut's keys, each lit and down while held (Try it shows these, without the glow).
    /// Ids are the modifier's place in the system's order, the key's 4: a cap keeps its identity as
    /// others join it.
    var keys: [Cap] {
        guard phase != .recording else { return live }
        guard let shortcut else { return [] }
        let modifiers = Self.flags(shortcut.modifiers)
        var caps: [Cap] = modifiers == Self.all ? [Self.hyper(held)] : Self.modifiers.enumerated().filter { modifiers.contains($1.flag) }.map { index, modifier in
            Cap(id: index, label: modifier.glyph, lit: held.contains(modifier.flag) ? 1 : 0, down: held.contains(modifier.flag))
        }
        // A registered hotkey never reaches the app as a key: live in Try it, the hotkey reports it.
        let down = key == UInt16(shortcut.keyCode) || ShortcutSettings.shared.down == .correct
        caps.append(Cap(id: 4, label: Shortcut.keyName(shortcut.keyCode), lit: down ? 1 : 0, down: down))
        return caps
    }

    /// "Hyper W" for the four-modifier chord, otherwise the modifiers' names.
    var spoken: String {
        guard let shortcut else { return "" }
        return shortcut.modifiers == Shortcut.hyper ? "Hyper " + Shortcut.keyName(shortcut.keyCode) : shortcut.spoken
    }

    /// While recording: the modifiers held so far, Hyper once all four are.
    private var live: [Cap] {
        if held.isSuperset(of: Self.all) { return [Self.hyper(held)] }
        return Self.modifiers.enumerated().filter { held.contains($1.flag) }.map { Cap(id: $0, label: $1.glyph, lit: 1, down: true) }
    }

    /// Hyper is often one remapped key: its modifiers light as they go down, the cap once all four are.
    private static func hyper(_ held: NSEvent.ModifierFlags) -> Cap {
        let all = held.isSuperset(of: Self.all)
        return Cap(id: 0, label: "Hyper", lit: all ? 1 : 0, down: all, parts: modifiers.enumerated().map { index, modifier in
            Cap(id: index, label: modifier.glyph, lit: held.contains(modifier.flag) ? 1 : 0, down: held.contains(modifier.flag))
        })
    }

    private static func flags(_ carbon: UInt32) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if carbon & UInt32(controlKey) != 0 { flags.insert(.control) }
        if carbon & UInt32(optionKey) != 0 { flags.insert(.option) }
        if carbon & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if carbon & UInt32(cmdKey) != 0 { flags.insert(.command) }
        return flags
    }

    // MARK: Listening

    func start() { listen(mirroring: false) }

    /// Try it's keys: they light as they go down while the hotkeys stay as they are, so the real
    /// shortcut corrects as it does anywhere; nothing is accepted or saved, and no key clicks over the
    /// correction's sounds. `heard` gets the shortcut and takes it (true) or lets it through.
    func mirror(heard: @escaping () -> Bool) {
        listen(mirroring: true)
        self.heard = heard
    }

    private func listen(mirroring: Bool) {
        if monitor != nil, self.mirroring == mirroring { return }
        stop()
        self.mirroring = mirroring
        if !mirroring {
            prepareSounds()
            ShortcutSettings.shared.pause()
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            guard let self, event.window?.identifier == Self.window else { return event }
            return handle(event) ? nil : event
        }
        // Elsewhere the shortcut corrects as usual; back here it reaches the step again. Keys let go
        // elsewhere never come back up here.
        let center = NotificationCenter.default
        let window = NSApp.windows.first { $0.identifier == Self.window }
        observers = [
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.letGo()
                    if self?.mirroring == false {
                        self?.sounds?.finish()
                        ShortcutSettings.shared.resume()
                    }
                }
            },
            center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if self?.mirroring == false {
                        self?.prepareSounds()
                        ShortcutSettings.shared.pause()
                    }
                }
            },
        ]
    }

    @discardableResult private func prepareSounds() -> HelloSounds? {
        guard Sounds.enabled else { return nil }
        if sounds == nil { sounds = HelloSounds(onlyKeyClicks: true) }
        return sounds
    }

    func stop() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor); self.monitor = nil
        observers.forEach(NotificationCenter.default.removeObserver); observers = []
        heard = nil
        letGo()
        if !mirroring {
            sounds?.finish()
            ShortcutSettings.shared.resume()
        }
    }

    private func letGo() {
        guard !held.isEmpty || key != nil else { return }
        withAnimation(.spring(duration: 0.18)) { held = []; key = nil }
    }

    private func press(_ keyCode: UInt16) {
        withAnimation(.spring(duration: 0.18, bounce: 0.35)) { key = keyCode }
        if !mirroring { prepareSounds()?.play(.key, gain: 0.6) }
    }

    /// True when the step used the key; Return and Escape go on to the window's buttons unless recording.
    private func handle(_ event: NSEvent) -> Bool {
        switch event.type {
        case .flagsChanged:
            let pressed = event.modifierFlags.intersection(Self.all).subtracting(held)
            withAnimation(.spring(duration: 0.18, bounce: 0.35)) {
                held = event.modifierFlags.intersection(Self.all)
                // A keyUp can go missing (⌘ or a hotkey takes it): the key goes once it is really up.
                if let key, !CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(key)) { self.key = nil }
            }
            if !pressed.isEmpty, !mirroring { prepareSounds()?.play(.key, gain: 0.6) }
            return false
        case .keyUp:
            if key == event.keyCode { withAnimation(.spring(duration: 0.18)) { key = nil } }
            return phase == .recording
        default: break
        }
        let modifiers = Shortcut.modifiers(event.modifierFlags)
        let pressed = Shortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers)
        if phase == .recording {
            if event.keyCode == 53, modifiers == 0 { cancelRecording(); return true }
            guard !event.isARepeat else { return true }
            press(event.keyCode)
            // A shortcut needs ⌃, ⌥ or ⌘; Shift alone would take a letter from every text field.
            guard modifiers & UInt32(controlKey | optionKey | cmdKey) != 0 else {
                if Sounds.enabled { NSSound.beep() }
                return true
            }
            record(pressed)
            return true
        }
        // The shortcut's key lights the moment it goes down, whatever is held with it.
        if UInt32(event.keyCode) == shortcut?.keyCode, !event.isARepeat { press(event.keyCode) }
        guard pressed == shortcut else { return false }
        if mirroring { return heard?() ?? false }
        if !event.isARepeat { accept() }
        return true
    }

    // MARK: Choosing

    func change() {
        error = nil
        acceptedBeforeChange = phase == .accepted
        withAnimation(.spring(duration: 0.4, bounce: 0.2)) { phase = .recording; glow = 0; check = 0; lid = 0; look = CGSize(width: 0, height: 0.8) }
    }

    func cancelRecording() {
        guard phase == .recording else { return }
        error = nil
        withAnimation(.spring(duration: 0.4, bounce: 0.2)) {
            if acceptedBeforeChange { phase = .accepted; glow = 0.3; check = 1; lid = 0; look = .zero }
            else { phase = .waiting; lid = 0; look = CGSize(width: 0, height: 0.7) }
        }
    }

    private func record(_ recorded: Shortcut) {
        do { try save(recorded) } catch {
            withAnimation(.spring(duration: 0.4)) { self.error = error.localizedDescription; lid = 0.55 }
            Sounds.play(.failure, after: 0)
            return
        }
        error = nil
        shortcut = recorded
        accept()
    }

    /// Saves a chord as Settings does; the default is stored as no custom shortcut at all.
    private func save(_ chord: Shortcut) throws {
        let settings = ShortcutSettings.shared
        guard saves else { return }
        try settings.set(.correct, chord == settings.defaultShortcut(.correct) ? nil : chord)
        // Saving registers the hotkeys again; here they stay paused.
        settings.pause()
    }

    private func accept() {
        let first = phase != .accepted
        withAnimation(.spring(duration: 0.5, bounce: 0.3)) { phase = .accepted; check = 1; lid = 0; look = .zero }
        glow = 1
        withAnimation(.easeOut(duration: 1.2).delay(0.25)) { glow = 0.3 }
        if first { Sounds.play(.success, after: 0) }
        announce(spoken)
    }

    #if DEBUG
    /// Sets a moment directly, for `-ShortcutSnapshots`.
    func seed(_ shortcut: Shortcut?, phase: Phase, held: NSEvent.ModifierFlags = [], key: UInt16? = nil, glow: Double = 0, error: String? = nil) {
        self.shortcut = shortcut; self.phase = phase; self.held = held; self.key = key; self.glow = glow; self.error = error
        check = phase == .accepted ? 1 : 0; lid = error == nil ? 0 : 0.55
        look = phase == .accepted ? .zero : CGSize(width: 0, height: phase == .recording ? 0.8 : 0.7)
    }
    #endif

    private func announce(_ message: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }
}
