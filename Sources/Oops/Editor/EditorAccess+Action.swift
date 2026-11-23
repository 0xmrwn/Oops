import AppKit
import ApplicationServices
import OopsCore

/// The draft no longer reads as an action captured or wrote it, or its selection moved: nothing is written.
struct ActionDraftChanged: LocalizedError {
    var errorDescription: String? { "The draft changed while the action ran. Nothing was replaced." }
}

/// An action's answer written over the span it read, and taken back out, in one paste through Fix's guarded swap
/// (`replace`: focus and remount checks, the selection proved before the paste, the paste confirmed). An action
/// rewrites, so unlike Fix it never goes in word by word: any length, code and mentions included. Nothing is moved onto
/// a draft that changed meanwhile, and an attachment is never pasted over, since nothing could bring it back.
extension EditorAccess {
    /// Replaces the selection, or the whole draft, with `answer`, while the editor holds exactly the draft and
    /// selection captured. Returns the snapshot the swap ended on (the app may have remounted the editor).
    func applyAction(_ answer: String, to snapshot: EditorSnapshot, clipboard: ClipboardLease,
                     protected: @Sendable () -> Bool) throws -> EditorSnapshot {
        var snapshot = snapshot
        let transaction = snapshot.transaction
        try follow(&snapshot, holding: transaction.before)
        // The reported selection, moved by the offset capture measured, as `apply` reads it.
        let selection = selection(snapshot.element, snapshot.strategy).flatMap {
            TextOffsets.plausible(location: $0.location + snapshot.rangeShift, length: $0.length + ($0.length > 0 ? snapshot.rangeLengthShift : 0))
        }
        guard let current = text(snapshot.element, snapshot.strategy), let selection else { throw ActionDraftChanged() }
        if !transaction.canApply(value: current, selection: selection) {
            // Chromium can read the same draft in display order: only a copy in the order typed shows it unchanged.
            guard selection == transaction.selection, Self.displayOrdered(current, transaction.before, snapshot),
                  try copyProves(transaction.before, around: transaction.range, in: snapshot, restore: transaction.selection,
                                 clipboard: clipboard, protected: protected)
            else { throw ActionDraftChanged() }
        }
        return try replace(snapshot, from: transaction.before, to: transaction.replacement(answer),
                           caret: transaction.caret(after: answer), clipboard: clipboard, protected: protected,
                           rewriting: transaction.range)
    }

    /// Puts the draft read at capture back, from `applied`, what the action left: only while the field still holds it.
    func restoreAction(_ snapshot: EditorSnapshot, from applied: String, clipboard: ClipboardLease,
                       protected: @Sendable () -> Bool) throws -> EditorSnapshot {
        var snapshot = snapshot
        let transaction = snapshot.transaction
        try follow(&snapshot, holding: applied)
        guard let current = text(snapshot.element, snapshot.strategy) else { throw ActionDraftChanged() }
        // What the action wrote, in the draft it left.
        let span = NSRange(location: transaction.range.location,
                           length: transaction.range.length + applied.utf16.count - transaction.before.utf16.count)
        if !sameDraft(current, applied) {
            guard Self.displayOrdered(current, applied, snapshot),
                  try copyProves(applied, around: span, in: snapshot, restore: NSRange(location: NSMaxRange(span), length: 0),
                                 clipboard: clipboard, protected: protected)
            else { throw ActionDraftChanged() }
        }
        return try replace(snapshot, from: applied, to: transaction.before, caret: transaction.selection,
                           clipboard: clipboard, protected: protected, rewriting: span)
    }

    /// Whether a copy shows the editor still holds `draft`; an editor that won't copy can't prove it.
    private func copyProves(_ draft: String, around range: NSRange, in snapshot: EditorSnapshot, restore: NSRange,
                            clipboard: ClipboardLease, protected: @Sendable () -> Bool) throws -> Bool {
        do {
            return try copyHolds(draft, around: range, in: snapshot, restore: restore, clipboard: clipboard,
                                 validate: { try self.stillSwapping(snapshot, protected) })
        } catch is DraftUncopiable { return false }
    }
}
