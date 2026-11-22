import AppKit
import OopsCore

/// What becomes of an agent run's result: taken back to its draft, dismissed, copied, undone, or run again.
extension AgentRun {
    /// The ready drop, the menu's item or the Actions shortcut: back to the draft. The drop is taken first: while
    /// another action or Fix is at work, the result stays ready, focus stays where it is, and the status line says why.
    func act() {
        guard flow.phase == .ready else { return }
        guard session?.isBusy != true, drop.claim() else {
            return refused("\(name) is ready. Put it in the draft once the action or correction under way is done.")
        }
        handle(.act)
    }

    /// The ready drop's close badge, or the menu's Discard.
    func dismiss() { if flow.phase == .ready { handle(.dismiss) } }

    func copy() {
        guard let copyable else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(copyable, forType: .string)
    }

    /// The failure drop's Try again: a run begun in Settings' Try goes back through Try, which reads its own draft only.
    func retry() {
        guard let session, let invocation else { return }
        if inTry { session.retryInTry(invocation) } else { _ = session.run(invocation) }
    }

    /// What the run wrote, as Actions keeps a model run's: the done drop's Undo and the wheel's restore petal both
    /// reach it, for as long as the done drop is up.
    func keep(_ written: ActionSession.Written) {
        guard let session, let invocation else { return }
        kept = written
        session.remember(written)
        session.last = invocation; session.lastInTry = inTry
    }

    /// The run's drop went away, or another feature took it: what it wrote can no longer be undone from it.
    func dropEnded() {
        guard !restoring, let kept, let session else { return }
        self.kept = nil
        if session.written?.applied == kept.applied { session.remember(nil) }
    }

    /// The done drop's undo: Actions' own restore, given what this run wrote, as the wheel's restore petal does.
    func restore() {
        guard let session, let kept else { return }
        restoring = true
        defer { restoring = false }
        session.remember(kept)
        if session.restore() == nil { session.remember(nil) }
        self.kept = nil
    }

    /// How the ready result ended, for the run's task.
    func resolve(_ outcome: ActionOutcome) {
        readyResult = outcome
        waiting?.resume(returning: outcome)
        waiting = nil
    }

    /// Waits for the ready result to be written, held or dismissed.
    func readyOutcome() async -> ActionOutcome {
        if let readyResult { return readyResult }
        return await withCheckedContinuation { waiting = $0 }
    }
}
