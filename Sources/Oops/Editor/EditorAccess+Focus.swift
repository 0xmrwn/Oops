import AppKit
import ApplicationServices

/// Which element holds the draft: the focused text field, or, when focus inside a web page rests
/// beside the editor, the field that holds the caret.
extension EditorAccess {
    /// The text field holding the page's caret, found through the selected text marker of the web
    /// area around `element` (or of the ones around that).
    nonisolated func caretHolder(_ element: AXUIElement) -> AXUIElement? {
        // Only from an option or a frame's document: focus on a button or a link means the person left the editor.
        guard [kAXStaticTextRole, "AXWebArea"].contains(attribute(element, kAXRoleAttribute) as? String ?? "") else { return nil }
        var node: AXUIElement? = element, areas = 0
        while let current = node, areas < 3 {
            if attribute(current, kAXRoleAttribute) as? String == "AXWebArea" {
                areas += 1
                if let markers = attribute(current, "AXSelectedTextMarkerRange"), CFGetTypeID(markers) == AXTextMarkerRangeGetTypeID(),
                   let leaf = parameterized(current, "AXUIElementForTextMarker", AXTextMarkerRangeCopyStartMarker(markers as! AXTextMarkerRange)),
                   CFGetTypeID(leaf) == AXUIElementGetTypeID() {
                    var holder = leaf as! AXUIElement
                    for _ in 0..<12 {
                        if textField(holder) != nil, !CFEqual(holder, element) { return holder }
                        guard let parent = attribute(holder, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
                        holder = parent as! AXUIElement
                    }
                }
            }
            node = attribute(current, kAXParentAttribute).flatMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
        }
        // A cross-origin frame's document, where WebKit stops focus when the frame runs in its own process
        // and whose markers don't reach into it: the focused field among its descendants, or its only one.
        guard attribute(element, kAXRoleAttribute) as? String == "AXWebArea" else { return nil }
        var pending = [element], visited = 0, fields: [AXUIElement] = []
        while !pending.isEmpty, visited < 400 {
            let next = pending.removeFirst(); visited += 1
            if !CFEqual(next, element), textField(next) != nil {
                if (attribute(next, kAXFocusedAttribute) as? NSNumber)?.boolValue == true { return next }
                fields.append(next); continue
            }
            pending += (attribute(next, kAXChildrenAttribute) as? [AXUIElement]) ?? []
        }
        return fields.count == 1 ? fields[0] : nil
    }

    /// A focused element Oops can edit: a text role, not secure, with a settable selection.
    nonisolated func textField(_ element: AXUIElement) -> (role: String, subrole: String?)? {
        let role = attribute(element, kAXRoleAttribute) as? String ?? ""
        let subrole = attribute(element, kAXSubroleAttribute) as? String
        // Gecko keeps role=document on a contenteditable paragraph. Require positive editability
        // as well as its text/selection APIs; ordinary document groups are not inputs.
        let editableDocument = role == kAXGroupRole && subrole == "AXDocument" && valueSettable(element) == true && isWebContent(element)
        guard [kAXTextAreaRole, kAXTextFieldRole, kAXComboBoxRole].contains(role) || subrole == kAXSecureTextFieldSubrole || editableDocument,
              subrole == kAXSecureTextFieldSubrole || attribute(element, kAXValueAttribute) is String,
              subrole == kAXSecureTextFieldSubrole || settable(element, kAXSelectedTextRangeAttribute) else { return nil }
        return (role, subrole)
    }
}
