import AppKit
import ApplicationServices
import OSLog
import OopsCore

/// Accessibility primitives: focus, attributes, ranges and geometry. They hold no state, so they run on
/// whichever queue calls them: the actor's own, or a Debug probe's.
extension EditorAccess {
    nonisolated func focused() throws -> AXUIElement {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            throw CorrectionError.message("No editable composer has focus.")
        }
        return value as! AXUIElement
    }
    /// Teams' WebView can report no focused element in any process until a client reads the
    /// frontmost app's role, windows and children.
    nonisolated func focusedWaking() throws -> AXUIElement {
        // Teams' composer lives in its WebView helper: wake and ask the frontmost app and the helper
        // processes nested in its bundle identifier, as the placement probe does.
        func processes() -> [AXUIElement] {
            guard let front = NSWorkspace.shared.frontmostApplication, let bundle = front.bundleIdentifier else { return [] }
            let helpers = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier?.hasPrefix(bundle + ".") == true }
            return ([front] + helpers).map { AXUIElementCreateApplication($0.processIdentifier) }
        }
        let resolved = try FocusWake.resolve(lookup: {
            if let element = try? self.focused() { return element }
            for app in processes() {
                if let value = self.attribute(app, kAXFocusedUIElementAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() { return (value as! AXUIElement) }
            }
            return nil
        }, wake: {
            for app in processes() {
                AXUIElementSetMessagingTimeout(app, 0.25)
                for name in [kAXRoleAttribute, kAXWindowsAttribute, kAXChildrenAttribute] { _ = self.attribute(app, name) }
            }
        }, check: { try Task.checkCancellation() }, attempts: 25)
        guard let resolved else { throw CorrectionError.message("No editable composer has focus.") }
        if resolved.retries > 0 {
            Self.captureLog.notice("focus_woken retries=\(resolved.retries, privacy: .public) bundle=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown", privacy: .public)")
        }
        return resolved.element
    }
    nonisolated func assertTarget(_ snapshot: EditorSnapshot) throws {
        if let hostPID = snapshot.hostPID, NSWorkspace.shared.frontmostApplication?.processIdentifier != hostPID {
            throw CorrectionError.message("Focus moved away from Teams. Your correction is ready to copy.")
        }
        let focused = try focused()
        var pid: pid_t = 0; AXUIElementGetPid(focused, &pid)
        // Focus on a menu option the editor points at still counts as the editor's.
        guard pid == snapshot.pid, CFEqual(focused, snapshot.element) || caretHolder(focused).map({ CFEqual($0, snapshot.element) }) == true else {
            throw CorrectionError.message("Focus moved to another editor. Your correction is ready to copy.")
        }
    }
    nonisolated func pid(of element: AXUIElement) -> pid_t {
        var pid: pid_t = 0; AXUIElementGetPid(element, &pid); return pid
    }
    nonisolated func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        AccessibilityExecution.perform(for: element) {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
            return value
        }
    }
    nonisolated func settable(_ element: AXUIElement, _ name: String) -> Bool {
        AccessibilityExecution.perform(for: element) {
            var result = DarwinBoolean(false)
            return AXUIElementIsAttributeSettable(element, name as CFString, &result) == .success && result.boolValue
        }
    }
    nonisolated func range(_ element: AXUIElement) -> NSRange? {
        guard let value = attribute(element, kAXSelectedTextRangeAttribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange(); guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return TextOffsets.plausible(location: range.location, length: range.length)
    }
    nonisolated func setRange(_ element: AXUIElement, _ range: NSRange) -> Bool {
        writeRange(element, range) == .success
    }
    nonisolated func writeRange(_ element: AXUIElement, _ range: NSRange) -> AXError {
        AccessibilityExecution.perform(for: element) {
            var value = CFRange(location: range.location, length: range.length)
            guard let ax = AXValueCreate(.cfRange, &value) else { return .illegalArgument }
            return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, ax)
        }
    }
    /// Geometry only, never text: the box, its ancestors and window, and caret candidates by text
    /// marker (WebKit, Chromium) or character range (AppKit). The placement engine validates them.
    nonisolated func geometry(_ element: AXUIElement) -> CapsulePlacement.Geometry {
        var ancestors: [CapsulePlacement.Ancestor] = [], node = element
        for _ in 0..<8 {
            guard let parent = attribute(node, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            let ancestor = parent as! AXUIElement
            let role = attribute(ancestor, kAXRoleAttribute) as? String ?? ""
            if let frame = frame(ancestor) { ancestors.append(.init(role: role, frame: frame)) }
            if role == kAXWindowRole { break }
            node = ancestor
        }
        let window = attribute(element, kAXWindowAttribute).flatMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? frame($0 as! AXUIElement) : nil }
        var caret: CGRect?, previous: CGRect?
        // Chromium answers markers with a zero-size placeholder (even for <textarea>, whose
        // character ranges do work) or, for contenteditable, the whole editor: keep caret-sized ones.
        if let markers = attribute(element, "AXSelectedTextMarkerRange"),
           let rect = parameterizedRect(element, "AXBoundsForTextMarkerRange", markers), rect.height > 0, rect.width <= 10 {
            caret = rect
        }
        if caret == nil, let selection = range(element) {
            caret = rangeRect(element, NSRange(location: selection.location, length: 0))
            if selection.location > 0 { previous = rangeRect(element, NSRange(location: selection.location - 1, length: 1)) }
        }
        return CapsulePlacement.Geometry(element: frame(element), ancestors: ancestors, window: window, caret: caret, previousCharacter: previous)
    }
    /// The text the element's character range covers.
    nonisolated func rangeString(_ element: AXUIElement, _ range: NSRange) -> String? {
        var value = CFRange(location: range.location, length: range.length)
        guard let parameter = AXValueCreate(.cfRange, &value) else { return nil }
        return AccessibilityExecution.perform(for: element) {
            var result: CFTypeRef?
            return AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString, parameter, &result)
                == .success ? result as? String : nil
        }
    }
    nonisolated func rangeRect(_ element: AXUIElement, _ range: NSRange) -> CGRect? {
        var value = CFRange(location: range.location, length: range.length)
        guard let parameter = AXValueCreate(.cfRange, &value) else { return nil }
        return parameterizedRect(element, kAXBoundsForRangeParameterizedAttribute, parameter)
    }
    nonisolated func parameterizedRect(_ element: AXUIElement, _ name: String, _ parameter: CFTypeRef) -> CGRect? {
        AccessibilityExecution.perform(for: element) {
            var value: CFTypeRef?, rect = CGRect.zero
            guard AXUIElementCopyParameterizedAttributeValue(element, name as CFString, parameter, &value) == .success,
                  let value, CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetValue(value as! AXValue, .cgRect, &rect) else { return nil }
            return rect
        }
    }
    nonisolated func frame(_ element: AXUIElement) -> CGRect? {
        guard let position = attribute(element, kAXPositionAttribute), let size = attribute(element, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &p), AXValueGetValue(size as! AXValue, .cgSize, &s) else { return nil }
        return CGRect(origin: p, size: s)
    }
    nonisolated func containsEmbeddedObject(_ element: AXUIElement, limit: Int) -> Bool {
        var pending = [element], visited = 0
        while let node = pending.popLast(), visited < limit {
            visited += 1
            let role = attribute(node, kAXRoleAttribute) as? String ?? ""
            if ["AXImage", "AXAttachment", "AXTokenField"].contains(role) { return true }
            if let children = attribute(node, kAXChildrenAttribute) as? [AXUIElement] { pending.append(contentsOf: children.prefix(limit - visited)) }
        }
        return false
    }
}
