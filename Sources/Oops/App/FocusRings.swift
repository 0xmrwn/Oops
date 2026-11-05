import AppKit
import Observation
import SwiftUI

/// Focus rings that wait for the keyboard, like the web's `:focus-visible`.
///
/// With Keyboard navigation on (System Settings › Keyboard) every control is a key view: a window
/// becoming key makes the first one first responder, and SwiftUI moves focus by itself when the
/// focused view leaves (an onboarding step or Settings page swaps) or a popover closes. AppKit and
/// SwiftUI draw the ring wherever focus is, however it got there, so it landed on controls nobody
/// tabbed to. Here focus effects draw only once Tab has moved focus since the last click, or while
/// a text field has focus: its ring says where typing goes, and a click or the code chose it.
@MainActor @Observable final class FocusRings {
    static let shared = FocusRings()
    /// Whether focus effects draw; window roots apply it with `focusRingsFromKeyboard()`.
    private(set) var shown = false
    /// Tab moved focus since the last click (in any Oops window, popovers included).
    @ObservationIgnored private(set) var tabbed = false
    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            self?.note(event)
            return event
        }
        // A popover or sheet taking or giving back the keyboard can start or end text editing.
        let center = NotificationCenter.default
        observers = [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification].map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            }
        }
    }

    /// A window opens without a ring, as a web page loads without one.
    func windowOpens() {
        tabbed = false
        update()
    }

    /// Recomputes `shown` once AppKit has settled focus; called after anything that moves it.
    func update() {
        let editing = NSApp.keyWindow?.firstResponder is NSText
        let shown = tabbed || editing
        if shown != self.shown { self.shown = shown }
    }

    private func note(_ event: NSEvent) {
        if event.type == .keyDown {
            // Tab and Shift-Tab, and Control-Tab out of a text view; ⌘ shortcuts are not navigation.
            guard event.keyCode == 48, !event.modifierFlags.contains(.command) else { return }
            tabbed = true
        } else {
            tabbed = false
        }
        // The event hasn't been handled yet: read focus after it has.
        DispatchQueue.main.async { [weak self] in self?.update() }
    }
}

/// An Oops window: nothing it shows starts focused unless the code or the user put focus there.
/// AppKit (with Keyboard navigation on) picks a first key view as a window becomes key, and SwiftUI
/// focuses its first control a turn later; dropping that also makes the first Tab start at the top.
/// A text field keeps its focus, so a key half-typed before switching to copy it is still there.
/// The SwiftUI root applies `focusRingsFromKeyboard()`.
final class FocusRingsWindow: NSWindow {
    override func makeKeyAndOrderFront(_ sender: Any?) {
        if !isVisible { FocusRings.shared.windowOpens() }
        super.makeKeyAndOrderFront(sender)
    }

    override func becomeKey() {
        super.becomeKey()
        DispatchQueue.main.async { [weak self] in
            guard let self, isKeyWindow, !FocusRings.shared.tabbed, !(firstResponder is NSText) else { return }
            makeFirstResponder(nil)
        }
    }

    @discardableResult override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        defer { DispatchQueue.main.async { FocusRings.shared.update() } }
        return super.makeFirstResponder(responder)
    }
}

extension View {
    /// Focus rings and other focus effects in this window draw only as `FocusRings` allows.
    func focusRingsFromKeyboard() -> some View { modifier(FocusRingsGate()) }
}

private struct FocusRingsGate: ViewModifier {
    func body(content: Content) -> some View {
        content.focusEffectDisabled(!FocusRings.shared.shown)
    }
}
