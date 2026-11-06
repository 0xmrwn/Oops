import AppKit
import OopsCore

/// Taking a correction back and putting it back (D10): Fix text pressed again on the draft it just
/// corrected restores the original, and once more re-applies the fix from memory.
extension CorrectionSession {
    /// Puts the last correction's original back, while the corrected draft is unchanged: Fix text pressed
    /// again, the drop's button, the menu or the restore shortcut.
    func revert() {
        guard task == nil else { return }
        guard let record = lastCorrection, record.toggle.canRestore() else {
            capsule.show(.failed, label: "Nothing to revert", detail: "There is no recent correction to revert.")
            capsule.hide(after: 1.5); return
        }
        swapBack(record, restoring: true)
    }

    /// Puts the fix back after a revert, without asking the provider: Fix text pressed on the restored draft.
    func reapply() {
        guard task == nil, let record = lastCorrection, record.toggle.state == .restored else { return }
        swapBack(record, restoring: false)
    }

    /// Whether the menu's Restore last correction has something to restore.
    var canRestore: Bool { task == nil && lastCorrection?.toggle.canRestore() == true }

    /// What this press of Fix text does to the draft just read: only the field Oops last corrected,
    /// holding exactly what Oops left there, is taken back or put back.
    func press(on snapshot: EditorSnapshot) async -> CorrectionToggle.Press {
        let text = snapshot.transaction.before
        // The field is checked last: only a draft that reads the same costs the Accessibility calls.
        guard let record = lastCorrection, snapshot.strategy != .copy,
              record.toggle.press(holding: text, sameField: true) != .correct else { return .correct }
        return record.toggle.press(holding: text, sameField: await editor.isSameEditor(snapshot, as: record.snapshot))
    }

    /// Keeps the last correction for five minutes after Oops last put either text in its field.
    func remember(_ record: LastCorrection?) {
        lastCorrection = record
        forgetting?.cancel()
        guard record != nil else { return }
        forgetting = Task { [weak self] in
            try? await Task.sleep(for: .seconds(CorrectionToggle.window))
            guard !Task.isCancelled, let self else { return }
            self.lastCorrection = nil; self.capsule.model.canRevert = false
            self.testEditor.restoreUnavailable()
        }
    }

    /// One swap between the fix and the original, either way through the same guarded swap, flash, drop,
    /// Stats and debug log label.
    private func swapBack(_ record: LastCorrection, restoring: Bool) {
        capsule.cancelTimedHide(); highlight.clear()
        let id = UUID(); generation = id
        let fixture = record.snapshot.pid == getpid() ? activeTry() : nil
        var snapshot = record.snapshot
        let toggle = record.toggle
        let (from, to) = restoring ? (toggle.applied, toggle.original) : (toggle.original, toggle.applied)
        task = Task {
            defer { if generation == id { task = nil } }
            do {
                // For the words' flash; Chromium's two-second debounce may outrun a quick swap.
                let fullAccessibility = await editor.enableFullAccessibility(for: snapshot)
                defer { if fullAccessibility { Task { await self.editor.disableFullAccessibility(for: snapshot) } } }
                guard try await swap(id, { clipboard, protected in
                    snapshot = restoring
                        ? try await self.editor.revert(snapshot, from: from, clipboard: clipboard, protected: protected)
                        : try await self.editor.replace(snapshot, from: from, to: to, caret: Self.caret(after: toggle, in: snapshot),
                                                        clipboard: clipboard, protected: protected)
                }) != nil, generation == id else { return }
                remember(.init(snapshot: snapshot, attempt: record.attempt, toggle: toggle.toggled()))
                capsule.model.canRevert = !restoring
                if restoring { DebugLog.recordRevert(of: record.attempt) } else { DebugLog.recordReapply(of: record.attempt) }
                if snapshot.pid != getpid() {
                    Stats.shared.record(.init(date: .now, outcome: restoring ? .reverted : .reapplied, app: snapshot.appName))
                }
                let diff = WordDiff(before: from, after: to)
                if restoring { fixture?.restored(corrected: from, original: to) } else { fixture?.corrected(before: from, expected: to, seconds: nil) }
                await flashHighlights(diff.afterRanges, in: snapshot, holding: to, offset: 0, style: restoring ? .restore : .correction,
                                      remounted: !CFEqual(snapshot.element, record.snapshot.element))
                let geometry = await editor.geometry(of: snapshot.element) ?? snapshot.geometry
                guard generation == id else { return }
                if restoring { capsule.show(.reverted, label: "Reverted", geometry: geometry) } else {
                    let fixes = TestEditorModel.fixesLabel(diff.changes)
                    capsule.show(.fixed, label: fixes, detail: Shortcut.undoHint(ShortcutSettings.shared.shortcut(.correct)),
                                 spoken: fixes + " put back", geometry: geometry)
                }
                capsule.hide(after: ResultTiming.seconds)
                capsule.follow(snapshot.element) { [editor = self.editor] element in await editor.geometry(of: element) ?? geometry }
            } catch is CancellationError {
                if generation == id { capsule.hide() }
            } catch {
                guard generation == id else { return }
                preferences.status = error.localizedDescription
                fixture?.failed(error.localizedDescription, remedy: nil)
                capsule.show(.failed, label: restoring ? "Couldn’t revert" : "Couldn’t re-apply", detail: error.localizedDescription)
                if await !editor.isInFront(snapshot), generation == id { capsule.unanchor() }
                guard generation == id, !Task.isCancelled else { return }
                capsule.hide(after: 8)
            }
        }
    }

    /// Where a correction leaves the caret: after the corrected span.
    private static func caret(after toggle: CorrectionToggle, in snapshot: EditorSnapshot) -> NSRange {
        NSRange(location: NSMaxRange(snapshot.transaction.range) + toggle.applied.utf16.count - toggle.original.utf16.count, length: 0)
    }
}

extension Shortcut {
    /// The one hint wherever a fix lands (D10): "Press ⌃⌘W again to undo".
    static func undoHint(_ shortcut: Shortcut?) -> String { "Press \(shortcut?.label ?? "Fix text") again to undo" }
}
