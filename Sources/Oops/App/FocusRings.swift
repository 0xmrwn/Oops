import AppKit
import Observation
import SwiftUI

/// Focus rings that wait for the keyboard, like the web's `:focus-visible`.
///
/// With Keyboard navigation on (System Settings › Keyboard) every control is a key view: a window
/// becoming key makes the first one first responder, and SwiftUI moves focus by itself when the
/// focused view leaves (an onboarding step or Settings page swaps) or a popover closes. AppKit and
/// SwiftUI draw the ring wherever focus is, however it got there, so it landed on controls nobody
/// tabbed to. Here focus effects draw only once Tab has moved focus since the last click, or on a
/// text field the person clicked into. Focus the code puts somewhere (a page's first field, the Try
/// draft taking the shortcut) shows nothing: no ring ever appears that the person didn't ask for.
@MainActor @Observable final class FocusRings {
    static let shared = FocusRings()
    /// Whether focus effects draw; window roots apply it with `focusRingsFromKeyboard()`.
    private(set) var shown = false
    /// Tab moved focus since the last click (in any Oops window, popovers included).
    @ObservationIgnored private(set) var tabbed = false
    /// The text field or text view the last click put the caret in.
    @ObservationIgnored private weak var clicked: NSView?
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
        clicked = nil
        update()
    }

    /// Recomputes `shown` once AppKit has settled focus; called after anything that moves it.
    func update() {
        let editing = clicked != nil && Self.edited(NSApp.keyWindow?.firstResponder) === clicked
        let shown = tabbed || editing
        if shown != self.shown { self.shown = shown }
    }

    private func note(_ event: NSEvent) {
        if event.type == .keyDown {
            // Tab and Shift-Tab, and Control-Tab out of a text view; ⌘ shortcuts are not navigation.
            guard event.keyCode == 48, !event.modifierFlags.contains(.command) else { return }
            tabbed = true
            // The event hasn't been handled yet: read focus after it has.
            DispatchQueue.main.async { [weak self] in self?.update() }
            return
        }
        tabbed = false
        let window = event.window
        let hit = window?.contentView.map { $0.hitTest($0.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow) } ?? nil
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // A click that lands on a text field and leaves the caret in it; a button that focuses one doesn't count.
            let edited = Self.edited(window?.firstResponder)
            clicked = edited.flatMap { hit?.isDescendant(of: $0) == true ? $0 : nil }
            update()
        }
    }

    /// The text field or text view a responder edits in: a field editor stands for its field.
    private static func edited(_ responder: NSResponder?) -> NSView? {
        guard let text = responder as? NSText else { return nil }
        return text.isFieldEditor ? text.delegate as? NSView : text
    }
}

/// An Oops window: nothing it shows starts focused unless the user put focus there. AppKit (with
/// Keyboard navigation on) picks a first key view as a window becomes key, and SwiftUI focuses its
/// first control a turn later; dropping that also makes the first Tab start at the top. A text field
/// takes focus only from a click in it, from Tab, or where the code asks on purpose (`placing`):
/// a caret blinking in a field nobody chose is focus appearing by itself. A text field keeps its
/// focus while the window is in the background, so a key half-typed before switching to copy it is
/// still there. The SwiftUI root applies `focusRingsFromKeyboard()`.
final class FocusRingsWindow: NSWindow {
    /// Set around a focus the code means: the Try draft, which the shortcut acts on.
    static var placing = false

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
        if let responder, Self.takesText(responder), !Self.placing, !chosen(responder) { return false }
        return super.makeFirstResponder(responder)
    }

    private static func takesText(_ responder: NSResponder) -> Bool {
        responder is NSText || (responder as? NSTextField)?.isEditable == true
    }

    /// Whether the event moving focus is the person's: Tab, or a click inside the field. VoiceOver
    /// moves focus through Accessibility, with no event of its own.
    private func chosen(_ responder: NSResponder) -> Bool {
        if NSWorkspace.shared.isVoiceOverEnabled { return true }
        guard let event = NSApp.currentEvent, event.window === self else { return false }
        switch event.type {
        case .keyDown: return event.keyCode == 48
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            guard let content = contentView, let field = (responder as? NSText).map({ $0.isFieldEditor ? $0.delegate as? NSView : $0 }) ?? responder as? NSView
            else { return false }
            let hit = content.hitTest(content.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow)
            // Inside the field, or in the margin of the scroll view a text view sits in.
            return hit?.isDescendant(of: field) == true || (hit as? NSScrollView)?.documentView === field
                || (hit as? NSClipView)?.documentView === field
        default: return false
        }
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
