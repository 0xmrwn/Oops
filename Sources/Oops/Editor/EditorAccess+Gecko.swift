import AppKit
import ApplicationServices
import OopsCore

/// Gecko (Firefox, Zen) starts its accessibility on the first request that reaches a window, and
/// only follows focus that moves after it: a field focused before then reads as the whole page, with
/// no selection, until focus moves again. So each Gecko process is asked once, the first time it
/// comes to the front (once it has a window), usually before the person has focused a field in it.
extension EditorAccess {
    nonisolated func selectGeckoWord(_ element: AXUIElement, edit: TextChange) -> AXError {
        guard let range = geckoWordRange(element, edit: edit) else { return .failure }
        return AccessibilityExecution.perform(for: element) {
            AXUIElementSetAttributeValue(element, "AXSelectedTextMarkerRange" as CFString, range)
        }
    }

    /// Gecko maps an index at a paragraph's start onto the preceding leaf, which can include an
    /// empty paragraph that neither its text nor a copy shows. Walk back from inside the word to
    /// keep the start in its own leaf, and require the same offsets and text before using the range.
    nonisolated func geckoWordRange(_ element: AXUIElement, edit: TextChange) -> CFTypeRef? {
        guard let first = edit.original.first, !edit.original.contains(where: \.isNewline),
              let base = markerBase(element),
              let inside = parameterized(element, "AXTextMarkerForIndex", (base + edit.location + first.utf16.count) as CFNumber),
              let start = parameterized(element, "AXPreviousTextMarkerForTextMarker", inside),
              (parameterized(element, "AXIndexForTextMarker", start) as? NSNumber)?.intValue == base + edit.location,
              let end = parameterized(element, "AXTextMarkerForIndex", (base + NSMaxRange(edit.range)) as CFNumber),
              let range = parameterized(element, "AXTextMarkerRangeForUnorderedTextMarkers", [start, end] as CFArray),
              let text = parameterized(element, "AXStringForTextMarkerRange", range) as? String,
              sameText(Self.visible(text), Self.visible(edit.original)), settable(element, "AXSelectedTextMarkerRange") else { return nil }
        return range
    }

    func wakeGecko(_ pid: pid_t) async {
        guard pid != getpid(), AXIsProcessTrusted(), geckoChecked.insert(pid).inserted,
              let app = NSRunningApplication(processIdentifier: pid), Self.isGecko(app) else { return }
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 0.25)
        // Still launching: look again soon, for up to ten seconds, to wake it before a page can focus a field.
        for attempt in 0..<100 where !app.isTerminated {
            if let window = (attribute(element, kAXWindowsAttribute) as? [AXUIElement])?.first {
                _ = attribute(window, kAXChildrenAttribute)
                _ = attribute(element, kAXFocusedUIElementAttribute)
                Self.captureLog.info("gecko_woken bundle=\(app.bundleIdentifier ?? "unknown", privacy: .public) attempt=\(attempt, privacy: .public)")
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Whether the snapshot's editor is in a Gecko app.
    static func isGecko(_ snapshot: EditorSnapshot) -> Bool {
        NSRunningApplication(processIdentifier: snapshot.hostPID ?? snapshot.pid).map(isGecko) ?? false
    }

    /// Every Gecko app ships its engine as Contents/MacOS/XUL.
    static func isGecko(_ app: NSRunningApplication) -> Bool {
        app.bundleURL.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("Contents/MacOS/XUL").path) } ?? false
    }
}
