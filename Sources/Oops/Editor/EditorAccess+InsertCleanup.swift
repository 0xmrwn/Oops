import AppKit
import ApplicationServices
import OopsCore

/// What a confirmed insert left in its field: the field's whole text then, and where the inserted text sits in it.
struct InsertedText {
    let element: AXUIElement
    let pid: pid_t
    let text: String
    let field: String
    let range: NSRange
}

/// Dictation's cleanup after the text is in: the inserted text is swapped for its cleanup through Fix's guarded swap,
/// and only while the field still reads exactly what the insert left there.
extension EditorAccess {
    /// Replaces `inserted`, which the last insert wrote, with `cleaned`. The field is read again first: another field,
    /// or the same one holding other text, is `.changed` and nothing is touched.
    func replaceInserted(_ inserted: String, with cleaned: String, clipboard: ClipboardLease,
                         protected: @Sendable () -> Bool) throws -> InsertReplacement {
        guard let record = lastInsert, sameText(record.text, inserted) else { return .changed }
        // Reading the field may switch on the app's full accessibility, as an insert does: off again unless it was on.
        let heldSwitch = switches.attribute(for: record.pid) != nil
        defer { if !heldSwitch { restoreFullAccessibility(pid: record.pid) } }
        let snapshot: EditorSnapshot
        do { snapshot = try capture() } catch is EmptyDraft { return .changed } catch is OpaqueEditor { return .changed }
        guard snapshot.pid == record.pid else { restoreFullAccessibility(pid: snapshot.pid); return .changed }
        guard CFEqual(snapshot.element, record.element), sameDraft(snapshot.transaction.before, record.field) else { return .changed }
        let after = (record.field as NSString).replacingCharacters(in: record.range, with: cleaned)
        _ = try replace(snapshot, from: record.field, to: after, caret: NSRange(location: record.range.location + cleaned.utf16.count, length: 0),
                        clipboard: clipboard, protected: protected)
        lastInsert = nil
        return .replaced
    }
}
