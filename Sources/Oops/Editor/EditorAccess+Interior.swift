import ApplicationServices
import OSLog
import OopsCore

extension EditorAccess {
    /// Gecko normalizes a space next to an image when deleting the adjacent whole word. After
    /// proving that word, retain its boundaries when the changed interior can be proved separately.
    func interiorInput(_ edit: TextChange, over draft: String, in snapshot: EditorSnapshot,
                       clipboard: ClipboardLease, validate: () throws -> Void) throws -> TextChange? {
        let element = snapshot.element
        guard let text = markerText(element), text.contains("\u{FFFC}"), let inner = TextEdits.interior(of: edit),
              let mapped = MarkerOffsets.range(inner.range, from: draft, to: text),
              let markers = geckoWordRange(element, edit: TextChange(location: mapped.location, original: inner.original,
                                                                    replacement: inner.replacement)) else { return nil }
        let write = {
            AccessibilityExecution.perform(for: element) {
                AXUIElementSetAttributeValue(element, "AXSelectedTextMarkerRange" as CFString, markers)
            }
        }
        try SelectionConfirmation.require(mapped, write: write, read: { self.markerSelection(element) }, validate: validate)
        guard selectedTextMatches(element, inner.original) != false,
              try editorHolds(inner.original, clipboard: clipboard, reselect: { _ = write() }, validate: validate)
        else { throw EditorKeptSelection() }
        Self.selectionLog.info("native_input_interior length=\(inner.original.utf16.count, privacy: .public)")
        let selected = selection(element, snapshot.strategy) ?? inner.range
        return TextChange(location: selected.location, original: inner.original, replacement: inner.replacement)
    }
}
