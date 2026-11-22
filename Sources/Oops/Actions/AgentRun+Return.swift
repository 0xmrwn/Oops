import AppKit
import OopsCore

/// How an agent run's answer reaches its draft: written in place when the person is still there, or after bringing
/// the draft's app, window and field back. Either way through Actions' guarded swap, which refuses a draft that
/// changed since it was read; then the answer waits in the drop to be copied.
extension AgentRun {
    /// Finished with the person in the field: the slow Fix.
    func writeInPlace() async -> ActionOutcome {
        defer { handle(.settled) }
        guard let session, let snapshot, let answer = held else { return .cancelled }
        held = nil
        drop.stopCancelling()
        return await write(answer, over: snapshot, session)
    }

    /// The ready result, taken back to its draft: the app, window and field come back, then the answer is written
    /// there if the draft is as it was. A field that is gone, or a draft that changed, leaves the answer to copy.
    func returnToDraft() async -> ActionOutcome {
        defer { handle(.settled) }
        guard let session, let snapshot, let answer = held else { return .cancelled }
        held = nil
        drop.showWorking("Returning…", geometry: await session.locate())
        // A dormant Chromium tree can't be focused, read or written: wake it for the return, as capture did.
        let woke = await session.editing.enableAccessibility(snapshot)
        let outcome: ActionOutcome
        if await session.editor.bringBack(snapshot) {
            outcome = await write(answer, over: snapshot, session)
        } else {
            copyable = answer
            drop.showHeld("The draft’s window or field is gone. The answer is ready to copy.", geometry: nil)
            outcome = .held
        }
        if woke { await session.editing.disableAccessibility(snapshot) }
        return outcome
    }

    private func write(_ answer: String, over snapshot: EditorSnapshot, _ session: ActionSession) async -> ActionOutcome {
        do {
            let applied = try await session.writeAgentAnswer(answer, over: snapshot)
            let restorable = snapshot.strategy != .copy
            if restorable { keep(.init(snapshot: applied, applied: snapshot.transaction.replacement(answer))) }
            let geometry = await session.editing.geometry(applied.element) ?? snapshot.geometry
            drop.showDone(name, elapsed: elapsed, canRestore: restorable, geometry: geometry, element: applied.element)
            return .written
        } catch {
            copyable = answer
            let words = Self.held(error)
            drop.showHeld(words.reason, label: words.label, geometry: nil)
            return .held
        }
    }

    /// What the drop says of an answer that wasn't written: a draft changed in part keeps its own words, as a model
    /// run's does; the answer is offered to copy either way.
    static func held(_ error: Error) -> (label: String, reason: String) {
        if let failure = error as? ActionFailure {
            return (failure.reason == .partial ? failure.label.text : "Not written", failure.message)
        }
        if error is ActionDraftChanged { return ("Not written", "The draft changed while the agent ran. The answer is ready to copy.") }
        return ("Not written", error.localizedDescription)
    }
}
