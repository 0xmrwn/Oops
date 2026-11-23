import AppKit
import OopsCore

/// What an agent run shares with model runs: the guarded swap that writes an answer, and the drop that says why a run
/// couldn't start.
extension ActionSession {
    /// Writes an agent's answer over the span `snapshot` read, through the swap a model run uses, while no model run
    /// holds the session. Refuses a draft that changed since it was read.
    func writeAgentAnswer(_ answer: String, over snapshot: EditorSnapshot) async throws -> EditorSnapshot {
        guard !isBusy else { throw ActionFailure(.model, "Another action was writing, so the answer wasn’t written. It’s ready to copy.") }
        agentWriting = true
        defer { agentWriting = false }
        let id = UUID(); generation = id
        let applied = try await editing.write(answer, snapshot, id)
        committed = snapshot.transaction.replacement(answer)
        return applied
    }

    /// Says in Actions' drop why `invocation`, an agent run, didn't start: at `geometry`, else where the person is. The
    /// drop's Try again repeats that run, through Try when it began there.
    func refuseAgent(_ failure: ActionFailure, _ invocation: ActionInvocation, inTry: Bool,
                     geometry: CapsulePlacement.Geometry? = nil) -> Task<ActionOutcome, Never>? {
        guard !isBusy, drop.claim(busy: { [weak self] in self?.isBusy == true }) else { return nil }
        remember(nil)
        last = invocation; lastInTry = inTry
        let id = UUID(); generation = id
        return Task { [weak self] in
            guard let self else { return .cancelled }
            let shown = if let geometry { geometry } else { await self.locate() }
            return self.fail(failure, id, geometry: shown)
        }
    }
}
