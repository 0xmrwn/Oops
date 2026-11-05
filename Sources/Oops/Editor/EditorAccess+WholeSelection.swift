import AppKit
import ApplicationServices
import OSLog
import OopsCore

/// The fallback when an editor keeps its own selection and never takes one from Accessibility: the
/// person's whole selection replaced at once, once a copy shows the editor still holds exactly it.
extension EditorAccess {
    /// The person's selection, replaced whole: for an editor that keeps its own selection and never
    /// takes one from Accessibility, once a copy shows it still holds exactly that text.
    func replaceSelection(_ snapshot: EditorSnapshot, _ selection: NSRange, from before: String, to after: String,
                          clipboard: ClipboardLease, protected: () -> Bool) throws -> EditorSnapshot {
        var snapshot = snapshot
        // The editor reported this selection: it must lie in the draft, and the correction must change nothing outside it.
        let changed = NSRange(location: selection.location, length: selection.length + after.utf16.count - before.utf16.count)
        guard NSMaxRange(selection) <= before.utf16.count, changed.length >= 0, NSMaxRange(changed) <= after.utf16.count,
              sameText((before as NSString).substring(to: selection.location), (after as NSString).substring(to: selection.location)),
              sameText((before as NSString).substring(from: NSMaxRange(selection)), (after as NSString).substring(from: NSMaxRange(changed)))
        else { throw EditorKeptSelection() }
        let original = (before as NSString).substring(with: selection)
        let replacement = (after as NSString).substring(with: changed)
        guard !Self.containsMentionOrCode(original), !original.contains("\u{FFFC}") else {
            throw CorrectionError.message("This editor keeps its own selection, and it holds a mention or an attachment. Select less text.")
        }
        Self.selectionLog.notice("replacement_whole_selection length=\(selection.length, privacy: .public)")
        func validate() throws {
            try Task.checkCancellation()
            guard protected() else { throw CorrectionError.message("The text-swap guard expired. Nothing replaced.") }
            try self.assertTarget(snapshot)
            guard let text = self.text(snapshot.element, snapshot.strategy), self.reads(text, as: before, snapshot) else {
                throw CorrectionError.message("The draft changed while confirming selection. Nothing replaced.")
            }
        }
        _ = select(snapshot.element, selection, snapshot.strategy)
        guard try editorHolds(original, clipboard: clipboard, reselect: { _ = self.select(snapshot.element, selection, snapshot.strategy) },
                              validate: validate) else { throw EditorKeptSelection() }
        try validate()
        try clipboard.install(replacement)
        try clipboard.requireOwnership()
        KeyboardGate.postCommand("v")
        var weakly = false
        guard confirm(&snapshot, holding: after, over: before, pasted: changed, distinct: { false }, weakly: &weakly) else {
            throw CorrectionError.message("The editor did not confirm the replacement. Check the draft before retrying; the original is available in the menu.")
        }
        return snapshot
    }
}
