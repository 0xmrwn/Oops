import AppKit
import ApplicationServices
import OSLog
import OopsCore

/// The revert: the correction taken back out of the editor, through the same guarded swap.
extension EditorAccess {
    /// Whether `now` was read from the editor `earlier` was: the same element, or the one the app remounted
    /// in its place (the earlier one gone, the new one focused in the same window and page, with the same role,
    /// where the earlier one was). An element can go stale while its field lives on beside a new one, so being
    /// gone alone doesn't make the new one a remount.
    func isSameEditor(_ now: EditorSnapshot, as earlier: EditorSnapshot) -> Bool {
        guard now.pid == earlier.pid else { return false }
        if CFEqual(now.element, earlier.element) { return true }
        guard now.role == earlier.role, let window = now.window, let before = earlier.window, CFEqual(window, before),
              let frame = now.geometry.element, let earlierFrame = earlier.geometry.element,
              CorrectionToggle.isRemount(frame, page: now.page, of: earlierFrame, page: earlier.page) else { return false }
        return attribute(earlier.element, kAXRoleAttribute) == nil
    }

    /// Puts the draft read at capture back, from `applied`: what the correction left in the editor.
    func revert(_ snapshot: EditorSnapshot, from applied: String, clipboard: ClipboardLease,
                protected: @Sendable () -> Bool) throws -> EditorSnapshot {
        var snapshot = snapshot
        try self.follow(&snapshot, holding: applied)
        guard let current = self.text(snapshot.element, snapshot.strategy) else {
            throw CorrectionError.message("The draft changed after correction. Revert would overwrite newer work.")
        }
        if sameDraft(current, applied) {
            return try self.replace(snapshot, from: applied, to: snapshot.transaction.before, caret: snapshot.transaction.selection,
                                    clipboard: clipboard, protected: protected)
        }
        // In display order, the draft must still copy as the correction left it; where the editor won't copy,
        // or the reading differs otherwise, revert on the reading when it differs only away from the fixes.
        if Self.displayOrdered(current, applied, snapshot) {
            let span = NSRange(location: snapshot.transaction.range.location,
                               length: snapshot.transaction.range.length + applied.utf16.count - snapshot.transaction.before.utf16.count)
            do {
                guard try copyHolds(applied, around: span, in: snapshot, restore: NSRange(location: NSMaxRange(span), length: 0),
                                    clipboard: clipboard, validate: { try self.stillSwapping(snapshot, protected) }) else {
                    throw CorrectionError.message("The draft changed after correction. Revert would overwrite newer work.")
                }
                return try self.replace(snapshot, from: applied, to: snapshot.transaction.before, caret: snapshot.transaction.selection,
                                        clipboard: clipboard, protected: protected)
            } catch is DraftUncopiable {}
        }
        guard let original = TextEdits.rebase(before: applied, after: snapshot.transaction.before, onto: current) else {
            throw CorrectionError.message("The draft changed after correction. Revert would overwrite newer work.")
        }
        Self.selectionLog.notice("draft_reread_rebased revert=true")
        return try self.replace(snapshot, from: current, to: original, caret: snapshot.transaction.selection,
                                clipboard: clipboard, protected: protected)
    }
}
