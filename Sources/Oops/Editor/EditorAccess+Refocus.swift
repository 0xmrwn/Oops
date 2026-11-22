import AppKit
import ApplicationServices
import OopsCore

/// Gives the field Oops read its focus and selection back after Oops's own field held the keys for a moment.
extension EditorAccess {
    /// The app in front again, the field focused, its selection as it was read. True when both read back so.
    /// A field only copy and paste reaches gets its app back and nothing more.
    func refocus(_ snapshot: EditorSnapshot) async -> Bool {
        let selection = Self.reported(snapshot.transaction.selection, shift: snapshot.rangeShift, lengthShift: snapshot.rangeLengthShift)
        await Self.bringToFront(snapshot.hostPID ?? snapshot.pid)
        guard snapshot.strategy != .copy else { return true }
        return refocus(element: snapshot.element, pid: snapshot.pid, selection: selection, strategy: snapshot.strategy)
    }

    /// The selection as the editor reports it, from the one capture corrected: capture measured `shift` and
    /// `lengthShift` as corrected minus reported, so they come off again.
    nonisolated static func reported(_ corrected: NSRange, shift: Int, lengthShift: Int) -> NSRange {
        NSRange(location: corrected.location - shift, length: corrected.length - (corrected.length > 0 ? lengthShift : 0))
    }

    /// The probe's form, from an element and a selection read beforehand. The selection is set and read back the way
    /// the capture read it: by character range, or through text markers.
    nonisolated func refocus(element: AXUIElement, pid: pid_t, selection: NSRange, strategy: CaptureStrategy = .value) -> Bool {
        _ = AccessibilityExecution.perform(for: element) {
            AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        }
        // Setting the same selection again is harmless and puts a caret some apps dropped back where it was.
        if self.selection(element, strategy) != selection { _ = select(element, selection, strategy) }
        guard let now = try? focused() else { return false }
        return CFEqual(now, element) && self.selection(element, strategy) == selection
    }

    /// Activates `pid` when another app is in front, and waits up to 300 ms for it to be.
    @MainActor private static func bringToFront(_ pid: pid_t) async {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier != pid,
              let app = NSRunningApplication(processIdentifier: pid) else { return }
        app.activate()
        for _ in 0 ..< 15 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
}
