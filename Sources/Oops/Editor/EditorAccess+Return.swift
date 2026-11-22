import AppKit
import ApplicationServices
import OopsCore

/// Finding a captured field again after the person has worked elsewhere: whether it still has focus, and bringing
/// back its app, window and field by identity, never by searching for one that looks like it.
extension EditorAccess {
    /// Whether the field read at capture is the one with focus now, in its app, in front.
    nonisolated func holdsFocus(_ snapshot: EditorSnapshot) -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == snapshot.hostPID ?? snapshot.pid else { return false }
        return (try? assertTarget(snapshot)) != nil
    }

    /// Brings the field read at capture back to the front and focuses it; true once it holds focus, on the same page
    /// for a web editor. False when its window or app has gone, or it won't take focus within a second and a half.
    /// Oops's own fields (Settings' Try) are AppKit's, so their attributes are set on the main thread.
    func bringBack(_ snapshot: EditorSnapshot) async -> Bool {
        let element = snapshot.element
        let gone = AccessibilityExecution.perform(for: element) {
            var role: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .invalidUIElement
        }
        if gone { Self.captureLog.notice("bring_back failed gone=true"); return false }
        let pid = snapshot.hostPID ?? snapshot.pid
        let app = AXUIElementCreateApplication(pid)
        AccessibilityExecution.perform(for: app) {
            if AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue) != .success {
                NSRunningApplication(processIdentifier: pid)?.activate()
            }
        }
        if let window = snapshot.window {
            AccessibilityExecution.perform(for: window) {
                AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
                AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            }
        }
        _ = AccessibilityExecution.perform(for: element) {
            AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        }
        for _ in 0 ..< 30 {
            if holdsFocus(snapshot), onPage(snapshot) { return true }
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return false }
        }
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        Self.captureLog.notice("bring_back failed front=\(front, privacy: .public) on_page=\(self.onPage(snapshot), privacy: .public)")
        return false
    }

    /// A web editor's page is still the one it was read on: a field of the same shape on another page isn't the draft.
    private nonisolated func onPage(_ snapshot: EditorSnapshot) -> Bool {
        guard let page = snapshot.page else { return true }
        return webArea(of: snapshot.element).flatMap(self.page(of:)) == page
    }

    /// Shares the Chromium switch Oops holds on the snapshot's app for as long as a long run needs it; false when
    /// there is none to share.
    func holdFullAccessibility(for snapshot: EditorSnapshot) -> Bool {
        guard switches.attribute(for: snapshot.pid) != nil else { return false }
        switches.hold(snapshot.pid)
        return true
    }

    /// Lets go of a hold; true when it was the last, so the switch may be turned off.
    func releaseFullAccessibility(for snapshot: EditorSnapshot) -> Bool { switches.release(snapshot.pid) }
}
