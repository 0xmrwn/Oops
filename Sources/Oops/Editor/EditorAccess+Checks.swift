import AppKit
import ApplicationServices
import OopsCore

/// What a readable field must pass before its text counts as a draft: no input method composing in
/// it, editable, not a masked secret, and not a hidden input proxy whose value isn't the text on screen.
extension EditorAccess {
    static let composingMessage = "An input method is still composing here. Finish typing, then try again."

    /// Why this field's text can't be corrected, or nil when it can.
    nonisolated func refusal(_ element: AXUIElement, field: (role: String, subrole: String?), strategy: CaptureStrategy,
                             value: String, webContent: Bool) -> CorrectionError? {
        // Marked text isn't the person's yet, and pasting under it breaks the composition.
        if composing(element) { return .message(Self.composingMessage) }
        if field.role != kAXTextAreaRole, SensitiveField.isMasked(value) { return .message("Oops doesn’t read password or code fields.") }
        if strategy != .markers, readOnly(element, webContent: webContent) {
            return .message("This text is read-only, so there’s no draft to correct. Click into a field you can edit.")
        }
        return nil
    }

    /// Whether the field takes no edits: its value can't be set. Web engines tie that to editability.
    /// Java's bridge never lets a text component's value be set, so outside web content a read-only
    /// field must also refuse a new selected text (AppKit's does; Catalyst and Qt report values settable).
    nonisolated func readOnly(_ element: AXUIElement, webContent: Bool) -> Bool {
        guard valueSettable(element) == false else { return false }
        return webContent || !settable(element, kAXSelectedTextAttribute)
    }

    /// An input method's marked text, while a composition is in progress: AppKit text views and
    /// WebKit report it as a character range, WebKit documents also as a text marker range.
    nonisolated func composing(_ element: AXUIElement) -> Bool {
        if let value = attribute(element, "AXTextInputMarkedRange"), CFGetTypeID(value) == AXValueGetTypeID() {
            var range = CFRange()
            if AXValueGetValue(value as! AXValue, .cfRange, &range), range.location != kCFNotFound, range.length > 0 { return true }
        }
        if let markers = attribute(element, "AXTextInputMarkedTextMarkerRange"), CFGetTypeID(markers) == AXTextMarkerRangeGetTypeID(),
           let text = parameterized(element, "AXStringForTextMarkerRange", markers) as? String {
            return !text.isEmpty
        }
        return false
    }

    /// Whether the field takes a new value: nil when it doesn't say. A read-only text view or
    /// textarea still lets its text be selected, but a paste does nothing.
    nonisolated func valueSettable(_ element: AXUIElement) -> Bool? {
        AccessibilityExecution.perform(for: element) {
            var result = DarwinBoolean(false)
            guard AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &result) == .success else { return nil }
            return result.boolValue
        }
    }

    /// A text input too small to show its own text: the hidden textarea or contenteditable that a
    /// canvas or painted editor (Monaco, Google Docs, Flutter) takes keys through. Its value is only
    /// the selection or the word before the caret, and selecting inside it doesn't move the editor's
    /// own selection, so only copy and paste of the selection can reach the draft.
    nonisolated func isInputProxy(_ element: AXUIElement) -> Bool {
        if frame(element).map(CapsulePlacement.isInputProxy) == true { return true }
        let classes = attribute(element, "AXDOMClassList") as? [String] ?? []
        let description = attribute(element, kAXRoleDescriptionAttribute) as? String
        guard classes.contains("inputarea") || description == "editor" else { return false }
        var node = element, ancestors: [[String]] = [], subroles: [String] = []
        for _ in 0..<8 {
            guard let parent = attribute(node, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            node = parent as! AXUIElement
            ancestors.append(attribute(node, "AXDOMClassList") as? [String] ?? [])
            if let subrole = attribute(node, kAXSubroleAttribute) as? String { subroles.append(subrole) }
            if attribute(node, kAXRoleAttribute) as? String == "AXWebArea" { break }
        }
        return InputProxy.matches(classes: classes, ancestors: ancestors, roleDescription: description, ancestorSubroles: subroles)
    }

    /// Whether the element is web content: a web area, or inside one. A web editor can keep a selection
    /// of its own apart from the DOM's, which Accessibility then echoes.
    nonisolated func isWebContent(_ element: AXUIElement) -> Bool {
        var node = element
        for _ in 0..<40 {
            if attribute(node, kAXRoleAttribute) as? String == "AXWebArea" { return true }
            guard let parent = attribute(node, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { return false }
            node = parent as! AXUIElement
        }
        return false
    }

    /// The roles around a focused element that exposes no text, for runs that score capture.
    nonisolated func logOpaque(_ element: AXUIElement, role: String) {
        var path: [String] = [], node = element
        for _ in 0..<6 {
            guard let parent = attribute(node, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            node = parent as! AXUIElement
            path.append(attribute(node, kAXRoleAttribute) as? String ?? "?")
        }
        let children = (attribute(element, kAXChildrenAttribute) as? [AXUIElement])?.count ?? -1
        var tree: [String] = [], pending = [(element, 0)]
        while !pending.isEmpty, tree.count < 40 {
            let (node, depth) = pending.removeFirst()
            let focused = (attribute(node, kAXFocusedAttribute) as? NSNumber)?.boolValue == true ? "*" : ""
            tree.append("\(depth):\(attribute(node, kAXRoleAttribute) as? String ?? "?")\(focused)")
            if depth < 6 { pending += ((attribute(node, kAXChildrenAttribute) as? [AXUIElement]) ?? []).map { ($0, depth + 1) } }
        }
        let frame = frame(element).map { "\(Int($0.width))x\(Int($0.height))" } ?? "none"
        Self.captureLog.notice("""
            capture_opaque role=\(role, privacy: .public) frame=\(frame, privacy: .public) children=\(children, privacy: .public) \
            ancestors=\(path.joined(separator: ">"), privacy: .public) markers=\(self.markerText(element)?.utf16.count ?? -1, privacy: .public) \
            tree=\(tree.joined(separator: ","), privacy: .public)
            """)
    }

    /// One line of numbers about the field being read, for runs that score capture (never its text).
    nonisolated func logField(_ element: AXUIElement, role: String, strategy: CaptureStrategy, value: String?, selection: NSRange?) {
        let frame = frame(element).map { "\(Int($0.width))x\(Int($0.height))" } ?? "none"
        let selected = (attribute(element, kAXSelectedTextAttribute) as? String)?.utf16.count
        let settable = (valueSettable(element).map { "\($0)" } ?? "unknown") + "/" + "\(self.settable(element, kAXSelectedTextAttribute))"
        let names = AccessibilityExecution.perform(for: element) {
            var names: CFArray?
            return AXUIElementCopyAttributeNames(element, &names) == .success ? (names as? [String] ?? []) : []
        }.filter { $0.contains("Marked") }.joined(separator: ",")
        let ranged = (attribute(element, kAXNumberOfCharactersAttribute) as? NSNumber)?.intValue ?? -1
        let markers = markerText(element)
        let images = containsEmbeddedObject(element, limit: 80)
        Self.captureLog.notice("""
            capture_field role=\(role, privacy: .public) strategy=\(strategy.rawValue, privacy: .public) frame=\(frame, privacy: .public) \
            value_len=\(value?.utf16.count ?? -1, privacy: .public) attachments=\(value?.unicodeScalars.count { $0 == "\u{FFFC}" } ?? 0, privacy: .public) \
            selection=\(selection.map { "\($0.location):\($0.length)" } ?? "none", privacy: .public) selected_len=\(selected ?? -1, privacy: .public) \
            value_settable=\(settable, privacy: .public) composing=\(self.composing(element), privacy: .public) images=\(images, privacy: .public) \
            marked_attrs=\(names, privacy: .public) characters=\(ranged, privacy: .public) \
            marker_len=\(markers?.utf16.count ?? -1, privacy: .public) marker_attachments=\(markers?.unicodeScalars.count { $0 == "\u{FFFC}" } ?? 0, privacy: .public)
            """)
    }
}
