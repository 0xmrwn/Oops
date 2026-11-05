#if DEBUG
import AppKit
import ApplicationServices
import OopsCore

/// Compatibility runs only (`fixtures/compat`): readies a scratch draft in the app in front, the way
/// a person would, and reports the focused field to `-ProbeState <file>`. Acts only on the app the
/// trigger names, and only while it is frontmost.
enum AppProbe {
    struct State: Codable {
        var action: String
        var bundle: String
        var ok: Bool
        var error: String?
        var role: String?
        var subrole: String?
        var value: String?
        var selection: [Int]?
        var placement: String?
        /// `outline`: the front window's tree, one "depth role/subrole size editable" line per node.
        var outline: [String]?
        /// The field's text through WebKit and Chromium text markers, when they answer.
        var markerText: String?
        /// The field's placeholder and description, to tell a placeholder reported as text apart.
        var placeholder: String?
        var fieldDescription: String?
        var date = Date()
    }

    static let queue = DispatchQueue(label: "oops.AppProbe")

    static func run(_ action: String, bundle: String, text: String?, placement: String?, editor: EditorAccess) {
        queue.async {
            var state = State(action: action, bundle: bundle, ok: true, placement: placement)
            do {
                guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundle else { throw Failure("\(bundle) isn’t in front (\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none") is)") }
                switch action {
                // `text` "web": the largest editable web document (Mail's body), even when a field has focus;
                // "largest": the largest editable field (a note's body rather than its title).
                case "focus": try focusEditor(editor, web: text == "web", largest: text == "largest")
                case "outline": state.outline = outline()
                // A scratch field's own text (the composer lab's sample), replaced by `text`.
                case "replace":
                    guard let element = focused(), let value = string(element, kAXValueAttribute) else { throw Failure("no field") }
                    var all = CFRange(location: 0, length: (value as NSString).length)
                    if let ax = AXValueCreate(.cfRange, &all) { AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, ax) }
                    Thread.sleep(forTimeInterval: 0.1)
                    try paste(text ?? "")
                // A new document, note or page in the app in front (⌘N).
                case "new": KeyboardGate.postCommand("n")
                case "remove": try remove(text ?? "", editor)
                case "type": try paste(text ?? "")
                case "read", "markers", "attributes", "bounds": break
                default: throw Failure("unknown action \(action)")
                }
                Thread.sleep(forTimeInterval: 0.3)
                if let raw = focused() {
                    let element = action == "markers" ? editor.caretHolder(raw) ?? raw : raw
                    state.role = string(element, kAXRoleAttribute)
                    state.subrole = string(element, kAXSubroleAttribute)
                    state.value = string(element, kAXValueAttribute)
                    if let range = range(element) { state.selection = [range.location, range.length] }
                    state.markerText = markerText(element)
                    state.placeholder = string(element, kAXPlaceholderValueAttribute)
                    state.fieldDescription = string(element, kAXDescriptionAttribute)
                    if action == "attributes" { state.outline = attributes(element) }
                    // `text` "location,length;…": what the highlight would get for each range, raw.
                    if action == "bounds" {
                        let ranges = (text ?? "").split(separator: ";").compactMap { pair -> NSRange? in
                            let parts = pair.split(separator: ",").compactMap { Int($0) }
                            return parts.count == 2 ? NSRange(location: parts[0], length: parts[1]) : nil
                        }
                        state.outline = ["frame \(String(describing: editor.frame(element)))"] + ranges.map { range in
                            "\(range): range \(String(describing: editor.rangeRect(element, range))) marker \(String(describing: editor.markerRect(element, range)))"
                        }
                    }
                    if action == "markers" {
                        let selected = editor.attribute(element, "AXSelectedTextMarkerRange")
                        let start = selected.flatMap { editor.parameterized(element, "AXStartTextMarkerForTextMarkerRange", $0) }
                        let index = start.flatMap { editor.parameterized(element, "AXIndexForTextMarker", $0) }
                        let length = selected.flatMap { editor.parameterized(element, "AXLengthForTextMarkerRange", $0) }
                        var names: CFArray?
                        AXUIElementCopyParameterizedAttributeNames(element, &names)
                        state.outline = ["selected \(selected != nil)", "start \(start != nil)", "index \(String(describing: index))",
                                         "length \(String(describing: length))", "settable \(editor.settable(element, "AXSelectedTextMarkerRange"))"]
                            + ((names as? [String]) ?? [])
                    }
                }
            } catch {
                state.ok = false; state.error = "\(error)"
            }
            write(state)
        }
    }

    struct Failure: Error, CustomStringConvertible { let description: String; init(_ text: String) { description = text } }

    private static func focused() -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    /// Focuses the largest editable text element in the frontmost window, unless one has focus. A
    /// dormant Chromium tree gets the accessibility switch first (recorded, so quitting restores it).
    private static func focusEditor(_ editor: EditorAccess, web: Bool, largest: Bool) throws {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { throw Failure("no frontmost app") }
        if web || largest { try focusLargest(pid, web: web); return }
        if let element = focused(), editable(element) { return }
        if (try? focusLargest(pid)) != nil { return }
        guard editor.setFullAccessibility(pid: pid, geometry: .init(element: nil, ancestors: [], window: nil, caret: nil, previousCharacter: nil)) else {
            try focusLargest(pid); return
        }
        Thread.sleep(forTimeInterval: 1.5)
        try focusLargest(pid)
    }

    /// An unfamiliar engine's field (Gecko): its attributes as "name [settable] type", never their
    /// values, its parameterized attributes, and its ancestors' roles.
    private static func attrClasses(_ element: AXUIElement) -> [String]? {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, "AXDOMClassList" as CFString, &value)
        return value as? [String]
    }

    private static func attributes(_ element: AXUIElement) -> [String] {
        var names: CFArray?, parameterized: CFArray?
        AXUIElementCopyAttributeNames(element, &names)
        AXUIElementCopyParameterizedAttributeNames(element, &parameterized)
        var lines = ((names as? [String]) ?? []).map { name in
            var value: CFTypeRef?, settable = DarwinBoolean(false)
            AXUIElementIsAttributeSettable(element, name as CFString, &settable)
            let type = AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success
                ? value.map { CFCopyTypeIDDescription(CFGetTypeID($0)) as String } ?? "nil" : "error"
            return "\(name)\(settable.boolValue ? " [settable]" : "") \(type)"
        }
        lines.append("classes " + (attrClasses(element) ?? []).joined(separator: " "))
        lines.append("parameterized: " + ((parameterized as? [String]) ?? []).joined(separator: " "))
        var node = element
        for _ in 0..<5 {
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(node, kAXParentAttribute as CFString, &parent) == .success, let parent,
                  CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            node = parent as! AXUIElement
            lines.append("parent \(string(node, kAXRoleAttribute) ?? "?")/\(string(node, kAXSubroleAttribute) ?? "") classes \((attrClasses(node) ?? []).joined(separator: " "))")
        }
        return lines
    }

    private static func frontWindow(_ pid: pid_t) throws -> AXUIElement {
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window else { throw Failure("no focused window") }
        return window as! AXUIElement
    }

    private static func outline() -> [String] {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier, let window = try? frontWindow(pid) else { return [] }
        var lines: [String] = [], pending = [(window, 0)]
        while let (node, depth) = pending.popLast(), lines.count < 400 {
            let size = frame(node).map { "\(Int($0.width))x\(Int($0.height))" } ?? "-"
            let role = string(node, kAXRoleAttribute) ?? "?"
            // Labels only (static text, buttons), never a field's contents.
            let label = [kAXStaticTextRole, kAXButtonRole].contains(role)
                ? " “" + String((string(node, kAXValueAttribute) ?? string(node, kAXTitleAttribute) ?? "").prefix(80)) + "”" : ""
            var focused: CFTypeRef?
            let isFocused = AXUIElementCopyAttributeValue(node, kAXFocusedAttribute as CFString, &focused) == .success && (focused as? Bool) == true
            lines.append("\(depth) \(role)/\(string(node, kAXSubroleAttribute) ?? "") \(size)\(editable(node) ? " editable" : "")\(isFocused ? " focused" : "")\(label)")
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(node, kAXChildrenAttribute as CFString, &children) == .success, let list = children as? [AXUIElement] {
                pending.append(contentsOf: list.reversed().map { ($0, depth + 1) })
            }
        }
        return lines
    }

    private static func focusLargest(_ pid: pid_t, web: Bool = false) throws {
        var pending = [try frontWindow(pid)], visited = 0, best: (element: AXUIElement, area: CGFloat)?
        while let node = pending.popLast(), visited < 4_000 {
            visited += 1
            // A web area stands in for a contenteditable document that has no text field yet (Mail's body).
            let isWeb = web && string(node, kAXRoleAttribute) == "AXWebArea"
            if web ? isWeb : editable(node) || isWeb,
               let size = frame(node)?.size, size.width * size.height > best?.area ?? 0 {
                best = (node, size.width * size.height)
            }
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(node, kAXChildrenAttribute as CFString, &children) == .success, let list = children as? [AXUIElement] {
                pending.append(contentsOf: list)
            }
        }
        guard let best else { throw Failure("no editable text element in \(visited) nodes") }
        AXUIElementSetAttributeValue(best.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    }

    private static func editable(_ element: AXUIElement) -> Bool {
        let role = string(element, kAXRoleAttribute) ?? ""
        guard [kAXTextAreaRole, kAXTextFieldRole].contains(role) else { return false }
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, kAXSelectedTextRangeAttribute as CFString, &settable) == .success && settable.boolValue
    }

    /// Deletes the probe's own text from the focused field, never anything else: selects its
    /// first occurrence through Accessibility, then presses Delete.
    private static func remove(_ text: String, _ editor: EditorAccess) throws {
        guard !text.isEmpty, let element = focused() else { throw Failure("no field to clean") }
        // A document with no plain value (Mail's body) is read and selected through text markers.
        let strategy: CaptureStrategy = (string(element, kAXValueAttribute) ?? "").contains(text) ? .value : .markers
        guard let value = editor.text(element, strategy) else { throw Failure("no text to clean") }
        let found = (value as NSString).range(of: text)
        guard found.location != NSNotFound else { return }
        guard editor.select(element, found, strategy) == .success else { throw Failure("couldn’t select the probe’s text") }
        Thread.sleep(forTimeInterval: 0.1)
        guard editor.selection(element, strategy) == found else {
            throw Failure("selection didn’t take: wanted \(found), read \(String(describing: editor.selection(element, strategy))), text at it \(String(describing: editor.markerString(element, found)))")
        }
        KeyboardGate.postKey(51, flags: [])
    }

    /// Pastes `text` at the caret, then puts the clipboard back.
    private static func paste(_ text: String) throws {
        let lease = try ClipboardLease()
        try lease.install(text)
        KeyboardGate.postCommand("v")
        Thread.sleep(forTimeInterval: 0.4)
        lease.restoreIfOwned()
    }

    private static func bool(_ element: AXUIElement, _ name: String) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let value else { return false }
        return (value as? Bool) ?? (CFGetTypeID(value) == AXUIElementGetTypeID())
    }

    private static func string(_ element: AXUIElement, _ name: String) -> String? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value as? String : nil
    }
    private static func range(_ element: AXUIElement) -> NSRange? {
        var value: CFTypeRef?, range = CFRange()
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success, let value,
              CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return NSRange(location: range.location, length: range.length)
    }
    private static func markerText(_ element: AXUIElement) -> String? {
        var range: CFTypeRef?, text: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, "AXTextMarkerRangeForUIElement" as CFString, element, &range) == .success, let range,
              AXUIElementCopyParameterizedAttributeValue(element, "AXStringForTextMarkerRange" as CFString, range, &text) == .success else { return nil }
        return text as? String
    }

    private static func frame(_ element: AXUIElement) -> CGRect? {
        var position: CFTypeRef?, size: CFTypeRef?, p = CGPoint.zero, s = CGSize.zero
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              AXValueGetValue(position as! AXValue, .cgPoint, &p), AXValueGetValue(size as! AXValue, .cgSize, &s) else { return nil }
        return CGRect(origin: p, size: s)
    }

    private static func write(_ state: State) {
        guard let url = DebugFlags.probeState else { return }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(state).write(to: url, options: .atomic)
    }
}
#endif
