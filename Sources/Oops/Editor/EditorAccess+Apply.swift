import AppKit
import ApplicationServices
import OSLog
import OopsCore

/// The editor stopped confirming partway: `applied` is the draft as the confirmed pastes left it,
/// in `snapshot`'s editor (the one that replaced the captured one, if the app remounted it).
struct PartialReplacement: LocalizedError {
    let applied: String
    let done: Int
    let total: Int
    let snapshot: EditorSnapshot
    var errorDescription: String? {
        "The editor confirmed \(done) of \(total) changes. Check the draft; the full correction is ready to copy."
    }
}

/// The guarded swap: for each changed span, last to first, select exactly that span, check the
/// editor selected that text, paste through the editor's own input path and confirm the result.
/// Text between the spans is never touched, and a draft that changed since it was read is never
/// touched at all. An editor the app remounts after an edit is followed to its new element; the
/// swap returns the snapshot with the element it ended on.
extension EditorAccess {
    func prepareClipboard() throws -> ClipboardLease {
        try ClipboardLease()
    }

    /// Returns the snapshot and the correction as applied, both moved onto the draft as the editor
    /// reported it again when that differs only away from the fixes.
    func apply(_ corrected: String, to snapshot: EditorSnapshot, clipboard: ClipboardLease,
               protected: @Sendable () -> Bool) throws -> (snapshot: EditorSnapshot, corrected: String) {
        var snapshot = snapshot, corrected = corrected
        var transaction = snapshot.transaction
        try self.follow(&snapshot, holding: transaction.before)
        let current = self.text(snapshot.element, snapshot.strategy), reported = self.selection(snapshot.element, snapshot.strategy)
        // The reported selection, moved by the offset capture measured: a selection extended or shrunk since
        // then no longer matches.
        let selection = reported.flatMap {
            TextOffsets.plausible(location: $0.location + snapshot.rangeShift, length: $0.length + ($0.length > 0 ? snapshot.rangeLengthShift : 0))
        }
        // Chromium can report the same draft in display order, its selection still counting as typed: the draft
        // stays as captured once a copy in the order typed shows it unchanged (an edit that only moved characters
        // reads the same). Where the editor won't copy, or the reading differs otherwise, the correction moves onto
        // the reading when nothing it changes differs (a reordered mention).
        var ordered = false
        if let current, let selection, !transaction.canApply(value: current, selection: selection), selection == transaction.selection {
            if Self.displayOrdered(current, transaction.before, snapshot) {
                do {
                    guard try copyHolds(transaction.before, around: transaction.range, in: snapshot, restore: transaction.selection,
                                        clipboard: clipboard, validate: { try self.stillSwapping(snapshot, protected) }) else {
                        throw CorrectionError.message("The draft or selection changed. Your correction is ready to copy.")
                    }
                    ordered = true
                } catch is DraftUncopiable {}
            }
            if !ordered, let moved = try? TextTransaction(value: current, selection: transaction.selection),
               let rebased = TextEdits.rebase(before: transaction.source, after: corrected, onto: moved.source) {
                Self.selectionLog.notice("draft_reread_rebased")
                transaction = moved; corrected = rebased; snapshot.transaction = moved
            }
        }
        guard let current, let selection, ordered || transaction.canApply(value: current, selection: selection) else {
            let current = self.text(snapshot.element, snapshot.strategy), selection = self.selection(snapshot.element, snapshot.strategy)
            // Where the text first differs, and what kind of character each side has there: never the text itself.
            let units = (current ?? "").unicodeScalars.map(\.self), was = transaction.before.unicodeScalars.map(\.self)
            let first = zip(units, was).prefix { $0 == $1 }.count
            func kind(_ scalars: [Unicode.Scalar]) -> String {
                first < scalars.count ? "\(scalars[first].properties.generalCategory)/\(scalars[first].value < 0x80 ? "ascii" : "other")" : "end"
            }
            Self.selectionLog.notice("""
                apply_draft_changed same_text=\(current.map { sameText($0, transaction.before) } ?? false, privacy: .public) \
                length=\(current?.utf16.count ?? -1, privacy: .public) selection=\(String(describing: selection), privacy: .public) \
                captured=\(String(describing: transaction.selection), privacy: .public) first_difference=\(first, privacy: .public) \
                now=\(kind(units), privacy: .public) was=\(kind(was), privacy: .public)
                """)
            throw CorrectionError.message("The draft or selection changed. Your correction is ready to copy.")
        }
        let applied = try self.replace(snapshot, from: transaction.before, to: try transaction.validatedReplacement(corrected),
                                       caret: transaction.caret(after: corrected), clipboard: clipboard, protected: protected)
        return (applied, corrected)
    }

    func replace(_ snapshot: EditorSnapshot, from before: String, to after: String, caret: NSRange, clipboard: ClipboardLease,
                 protected: () -> Bool) throws -> EditorSnapshot {
        if sameText(before, after) { return snapshot }
        let edits = TextEdits.between(before, after)
        guard !edits.contains(where: { Self.containsMentionOrCode($0.original) || $0.original.contains("\u{FFFC}") }) else {
            throw CorrectionError.message("The edited span crosses code, a mention or an attachment. Select a smaller text span to preserve it.")
        }
        try Task.checkCancellation()
        var snapshot = snapshot
        try follow(&snapshot, holding: before)
        let original = snapshot.element
        guard !composing(snapshot.element) else { throw CorrectionError.message(Self.composingMessage) }
        guard let current = text(snapshot.element, snapshot.strategy), reads(current, as: before, snapshot) else {
            throw CorrectionError.message("The draft changed just before replacement. Nothing replaced.")
        }
        let initial = selection(snapshot.element, snapshot.strategy)
        var draft = before, weakly = false
        for (done, edit) in edits.reversed().enumerated() {
            let next = (draft as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
            do {
                try follow(&snapshot, holding: draft)
                do {
                    try paste(edit, in: &snapshot, over: draft, giving: next, restoring: done == 0 ? initial : nil,
                              weakly: &weakly, clipboard: clipboard, protected: protected)
                } catch let error where !(error is UnconfirmedPaste || error is UndonePaste) {
                    // Remounted before this span was pasted: nothing went in, so do it again in the new editor.
                    guard remounted(snapshot, holding: draft) != nil else { throw error }
                    try follow(&snapshot, holding: draft)
                    try paste(edit, in: &snapshot, over: draft, giving: next, restoring: done == 0 ? initial : nil,
                              weakly: &weakly, clipboard: clipboard, protected: protected)
                }
            } catch let undone as UndonePaste {
                // The text is the draft before this span again, with the confirmed spans in it.
                guard done > 0 else { throw undone }
                throw PartialReplacement(applied: draft, done: done, total: edits.count, snapshot: snapshot)
            } catch is EditorKeptSelection where done == 0 && (initial?.length ?? 0) > 0 {
                // The editor still holds the person's own selection: replace it whole instead.
                return try replaceSelection(snapshot, initial!, from: before, to: after, clipboard: clipboard, protected: protected)
            } catch {
                guard done > 0 else { throw error }
                // A paste confirmed only by the letters the text holds isn't proved: no partial revert from it.
                guard !weakly else { throw UnconfirmedPaste() }
                // Only a draft known to hold the confirmed pastes can be reverted from.
                let value = text(snapshot.element, snapshot.strategy)
                // In display order a fix that only moves letters reads as either: unknown, so not revertible.
                guard let value, let applied = DisplayOrder.base(of: value, among: [draft, next], ordered: snapshot.webContent)
                else { throw error }
#if DEBUG
                Self.selectionLog.notice("replacement_partial_cause \(error.localizedDescription, privacy: .public)")
#endif
                Self.selectionLog.notice("replacement_partial done=\(done, privacy: .public) total=\(edits.count, privacy: .public)")
                throw PartialReplacement(applied: applied, done: sameText(applied, next) ? done + 1 : done, total: edits.count,
                                         snapshot: snapshot)
            }
            draft = next
        }
        // The last paste can remount the editor after confirming, too. Follow it before the
        // final copy proof, which otherwise asks a discarded AX element to take a selection.
        try follow(&snapshot, holding: draft)
        // An editor seen rebuilding itself after an edit does so after this last one too: follow it there,
        // so the caret, the flash and the capsule land in the new one.
        // It may rebuild more than once: wait until it has stayed put for 200 ms, at most 0.8 s.
        if !CFEqual(snapshot.element, original) {
            let deadline = ProcessInfo.processInfo.systemUptime + 0.8
            var settled = ProcessInfo.processInfo.systemUptime
            while ProcessInfo.processInfo.systemUptime < deadline, ProcessInfo.processInfo.systemUptime - settled < 0.2 {
                if let moved = remounted(snapshot, holding: draft) { snapshot.element = moved; settled = ProcessInfo.processInfo.systemUptime }
                Thread.sleep(forTimeInterval: 0.025)
            }
        }
        // Confirmed only by which characters the text holds, so an editor that rearranged text as it pasted
        // would read the same: a copy in the order typed proves the result, from the first fix to the last at least.
        if weakly, let first = edits.first, let last = edits.last {
            let end = NSMaxRange(last.range) + draft.utf16.count - before.utf16.count
            let fixed = NSRange(location: first.location, length: end - first.location)
            let holds = try? copyHolds(draft, around: fixed, in: snapshot, restore: caret, clipboard: clipboard,
                                       validate: { try Task.checkCancellation(); try self.assertTarget(snapshot) })
            guard let holds else { throw UnconfirmedPaste() }
            guard holds else { throw UnconfirmedPaste(beside: true) }
        }
        _ = select(snapshot.element, caret, snapshot.strategy)
        return snapshot
    }

    static func containsMentionOrCode(_ text: String) -> Bool {
        text.contains("`") || text.range(of: #"@[\p{L}\p{N}_-]+"#, options: .regularExpression) != nil
    }
}
