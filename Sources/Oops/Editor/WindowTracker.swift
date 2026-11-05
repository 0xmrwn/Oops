import AppKit
import ApplicationServices

/// Calls back when another app's editor window moves or resizes (and, when asked, when the
/// editor's text or selection changes), through an AXObserver on the main run loop. Only active
/// while the capsule or a highlight is visible.
@MainActor final class WindowTracker {
    private static let notifications = [kAXMovedNotification, kAXResizedNotification]
    private var observer: AXObserver?
    private var window: AXUIElement?
    private var element: AXUIElement?
    private var elementNotifications: [String] = []
    private var onChange: (() -> Void)?

    func track(_ element: AXUIElement, elementNotifications: [String] = [], onChange: @escaping () -> Void) {
        stop()
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid != getpid() else { return }
        AXUIElementSetMessagingTimeout(element, 0.25)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return }
        let window = value as! AXUIElement
        var created: AXObserver?
        guard AXObserverCreate(pid, { _, _, _, refcon in
            guard let refcon else { return }
            let tracker = Unmanaged<WindowTracker>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { tracker.onChange?() }
        }, &created) == .success, let created else { return }
        // Unretained: `stop()` removes the notifications before this tracker can go away.
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in Self.notifications { AXObserverAddNotification(created, window, name as CFString, refcon) }
        for name in elementNotifications { AXObserverAddNotification(created, element, name as CFString, refcon) }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
        observer = created; self.window = window; self.element = element
        self.elementNotifications = elementNotifications; self.onChange = onChange
    }

    func stop() {
        if let observer, let window {
            for name in Self.notifications { AXObserverRemoveNotification(observer, window, name as CFString) }
            if let element { for name in elementNotifications { AXObserverRemoveNotification(observer, element, name as CFString) } }
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil; window = nil; element = nil; elementNotifications = []; onChange = nil
    }
}
