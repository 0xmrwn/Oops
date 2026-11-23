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
        drop.showWriting(Self.placing)
        return await write(answer, over: snapshot, session, inPlace: true)
    }

    /// The ready result, taken back to its draft: the app, window and field come back, then the answer is written
    /// there if the draft is as it was. A field that is gone, or a draft that changed, leaves the answer to copy.
    func returnToDraft() async -> ActionOutcome {
        defer { handle(.settled) }
        guard let session, let snapshot, let answer = held else { return .cancelled }
        held = nil
        drop.showWorking("Returning to the draft", geometry: await session.locate())
        // A dormant Chromium tree can't be focused, read or written: wake it for the return, as capture did.
        let woke = await session.editing.enableAccessibility(snapshot)
        let outcome: ActionOutcome
        if await session.editor.bringBack(snapshot) {
            drop.showWriting(Self.placing)
            outcome = await write(answer, over: snapshot, session, inPlace: false)
        } else {
            copyable = answer
            drop.showHeld("The draft’s window or field is gone. The answer is ready to copy.", geometry: nil)
            outcome = .held
        }
        if woke { await session.editing.disableAccessibility(snapshot) }
        return outcome
    }

    /// `inPlace`: the person watched the timer run to the write, so the done drop's time goes on from it; a run taken
    /// back later shows the time it took to answer.
    private func write(_ answer: String, over snapshot: EditorSnapshot, _ session: ActionSession, inPlace: Bool) async -> ActionOutcome {
        do {
            let applied = try await session.writeAgentAnswer(answer, over: snapshot)
            let restorable = snapshot.strategy != .copy
            if restorable { keep(.init(snapshot: applied, applied: snapshot.transaction.replacement(answer))) }
            let geometry = await session.editing.geometry(applied.element) ?? snapshot.geometry
            let time = inPlace ? progress.map { $0.start.duration(to: .now) } ?? elapsed : elapsed
            drop.showDone(Self.done(name, summary: progress?.summary, elapsed: time), spoken: name + " done", canRestore: restorable,
                          geometry: geometry, element: applied.element)
            return .written
        } catch {
            copyable = answer
            let words = Self.held(error)
            drop.showHeld(words.reason, label: words.label, geometry: nil)
            return .held
        }
    }

    /// What the drop says of an answer that wasn't written; the answer is offered to copy.
    static func held(_ error: Error) -> (label: String, reason: String) {
        if let failure = error as? ActionFailure { return ("Not written", failure.message) }
        if error is ActionDraftChanged { return ("Not written", "The draft changed while the agent ran. The answer is ready to copy.") }
        return ("Not written", error.localizedDescription)
    }
}
