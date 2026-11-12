import AppKit
import ApplicationServices
import OopsCore

/// What reading a draft and writing at the caret both settle first: which app the focused element
/// belongs to and what the policy says of it, and the text field under focus once a dormant tree is awake.
extension EditorAccess {
    struct Scope {
        let app: NSRunningApplication
        let foreground: NSRunningApplication?
        let verdict: EditorApplicationPolicy.Verdict
        /// The app as the person knows it: the frontmost app for a helper nested in it.
        let name: String
    }

    /// The app that owns `pid`'s focused element, under the application policy; nil when it isn't running.
    nonisolated func scope(of pid: pid_t) -> Scope? {
        let foreground = NSWorkspace.shared.frontmostApplication
        guard let app = NSRunningApplication(processIdentifier: pid) else { return nil }
        let verdict = EditorApplicationPolicy.verdict(bundleID: app.bundleIdentifier, bundleURL: app.bundleURL,
                                                      foregroundBundleID: foreground?.bundleIdentifier,
                                                      foregroundBundleURL: foreground?.bundleURL, turnedOff: AppScope.current)
        let name = (EditorApplicationPolicy.isNested(app.bundleURL, in: foreground?.bundleURL) ? foreground : app)?.localizedName ?? "this app"
        Self.captureLog.info("editor_scope bundle=\(app.bundleIdentifier ?? "unknown", privacy: .public) verdict=\(String(describing: verdict), privacy: .public)")
        return Scope(app: app, foreground: foreground, verdict: verdict, name: name)
    }

    /// The text field at `element`, which moves onto it when focus rests beside it. `awakeDocument`: no
    /// field, but a document whose markers already read text.
    func wakingField(_ element: inout AXUIElement, pid: pid_t) throws -> (field: (role: String, subrole: String?)?, awakeDocument: Bool) {
        // An Electron or Chromium editor whose tree is still dormant has no text to read yet:
        // set the host's accessibility switch and wait for its field to come alive. A document
        // whose markers already read a draft is awake: waking it would only cost a second.
        var field = self.textField(element)
        let awakeDocument = field == nil && !(self.markerText(element) ?? "").isEmpty && self.supportsMarkers(element)
        if field == nil, !awakeDocument, self.setFullAccessibility(pid: pid, geometry: self.geometry(element)) {
            for _ in 0..<20 where field == nil {
                do { try Task.checkCancellation() } catch { self.restoreFullAccessibility(pid: pid); throw error }
                Thread.sleep(forTimeInterval: 0.05)
                // Only the same app's editor: focus moving elsewhere meanwhile must not be read under this app's verdict.
                if let woken = try? self.focused(), self.pid(of: woken) == pid { element = woken; field = self.textField(element) }
            }
            Self.captureLog.notice("capture_woke_chromium found=\(field != nil, privacy: .public)")
            if field == nil { self.restoreFullAccessibility(pid: pid) }
        }
        // In a web page, focus can rest beside the editor: on a menu option the editor points at
        // (aria-activedescendant), or on a cross-origin frame's document. The editor holds the caret.
        if field == nil, let holder = self.caretHolder(element), let found = self.textField(holder) { element = holder; field = found }
        return (field, awakeDocument)
    }
}
