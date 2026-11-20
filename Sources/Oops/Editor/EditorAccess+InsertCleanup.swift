import AppKit
import ApplicationServices
import OopsCore

/// What a confirmed insert left in its field: the field's whole text then, and where the inserted text sits in it.
struct InsertedText {
    let element: AXUIElement
    let pid: pid_t
    /// The app in front when the field belongs to a helper nested in it (Teams' WebView).
    let hostPID: pid_t?
    /// How the field's text read back the insert, and so how it is read again.
    let strategy: CaptureStrategy
    let role: String
    let text: String
    let field: String
    let range: NSRange
}

/// Dictation's cleanup after the text is in: the inserted text is swapped for its cleanup through Fix's guarded swap,
/// and only while the field still reads exactly what the insert left there. The field is read as the insert read it,
/// not as a draft: a long document has no draft's length limit here.
extension EditorAccess {
    /// Replaces `inserted`, which the last insert wrote, with `cleaned`. The field is read again first: another field,
    /// or the same one holding other text, is `.changed` and nothing is touched.
    func replaceInserted(_ inserted: String, with cleaned: String, clipboard: ClipboardLease,
                         protected: @Sendable () -> Bool) throws -> InsertReplacement {
        guard let record = lastInsert, sameText(record.text, inserted) else { return .changed }
        // Reading the field may switch on the app's full accessibility, as an insert does: off again unless it was on.
        let heldSwitch = switches.attribute(for: record.pid) != nil
        defer { if !heldSwitch { restoreFullAccessibility(pid: record.pid) } }
        guard let read = readInserted(record), sameDraft(read.text, record.field),
              let snapshot = insertSnapshot(record, text: read.text, selection: read.selection) else { return .changed }
        let after = (record.field as NSString).replacingCharacters(in: record.range, with: cleaned)
        _ = try replace(snapshot, from: record.field, to: after, caret: NSRange(location: record.range.location + cleaned.utf16.count, length: 0),
                        clipboard: clipboard, protected: protected)
        lastInsert = nil
        return .replaced
    }

    /// Whether the field the last insert wrote `inserted` into still has focus, reads what the insert left there and
    /// has its caret right after it. Read only, the same way `replaceInserted` reads it.
    func insertedIntact(_ inserted: String) -> Bool {
        guard let record = lastInsert, sameText(record.text, inserted) else { return false }
        let heldSwitch = switches.attribute(for: record.pid) != nil
        defer { if !heldSwitch { restoreFullAccessibility(pid: record.pid) } }
        guard let read = readInserted(record) else { return false }
        return sameDraft(read.text, record.field) && read.selection == NSRange(location: NSMaxRange(record.range), length: 0)
    }

    /// The inserted field's text and selection, while it still has focus. The app in front is checked before anything
    /// is asked of an app, so a press in an unrelated one costs nothing and wakes nothing (with the microphone not kept
    /// ready, that delay would clip the recording's first words); only then is the field's own app woken, if needed.
    private func readInserted(_ record: InsertedText) -> (text: String, selection: NSRange)? {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == record.hostPID ?? record.pid,
              let front = try? focusedWaking(), pid(of: front) == record.pid,
              CFEqual(front, record.element) || caretHolder(front).map({ CFEqual($0, record.element) }) == true else { return nil }
        if let text = text(record.element, record.strategy), let selection = selection(record.element, record.strategy) {
            return (text, selection)
        }
        // A Chromium tree that went dormant again once the insert switched its accessibility off.
        var element = record.element
        guard (try? wakingField(&element, pid: record.pid)) != nil, let text = text(record.element, record.strategy),
              let selection = selection(record.element, record.strategy) else { return nil }
        return (text, selection)
    }

    /// The inserted field as Fix's swap takes it, built from the insert's record rather than captured as a draft.
    private func insertSnapshot(_ record: InsertedText, text: String, selection: NSRange) -> EditorSnapshot? {
        guard let transaction = try? TextTransaction(value: text, selection: selection, maximumSourceLength: .max) else { return nil }
        let app = NSRunningApplication(processIdentifier: record.pid), host = record.hostPID.flatMap(NSRunningApplication.init(processIdentifier:))
        let webArea = webArea(of: record.element)
        return EditorSnapshot(element: record.element, pid: record.pid, hostPID: record.hostPID,
                              appName: (host ?? app)?.localizedName ?? "", bundleID: app?.bundleIdentifier,
                              owner: (host ?? app)?.bundleIdentifier ?? "", appVersion: nil, role: record.role,
                              subrole: attribute(record.element, kAXSubroleAttribute) as? String, transaction: transaction,
                              geometry: geometry(record.element), strategy: record.strategy, webContent: webArea != nil,
                              page: webArea.flatMap(page(of:)),
                              window: attribute(record.element, kAXWindowAttribute).flatMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil })
    }
}
