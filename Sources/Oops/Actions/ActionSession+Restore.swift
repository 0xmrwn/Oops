import AppKit
import OopsCore

/// Writing an answer through Fix's guarded swap, and putting the original back while the result shows.
extension ActionSession {
    /// The guarded swap Fix uses (`CorrectionSession.swap`): wait for the shortcut's keys to be let go, lease the
    /// clipboard, hold input while the editor is written, then give both back.
    func swap(_ id: UUID, _ replace: (ClipboardLease, @escaping @Sendable () -> Bool) async throws -> Void) async throws {
        try await KeyboardGate.waitForModifierRelease()
        let clipboard = try await editor.prepareClipboard()
        try checkCurrent(id)
        let gate = try KeyboardGate()
        committing = true; drop.canCancel = false
        defer { gate.release(); committing = false; drop.canCancel = true; clipboard.restoreIfOwned() }
        try await replace(clipboard) { gate.isActive }
    }

    /// Writes `answer` over the span `snapshot` read; returns the snapshot the swap ended on.
    func write(_ answer: String, over snapshot: EditorSnapshot, _ id: UUID) async throws -> EditorSnapshot {
        var applied = snapshot
        try await swap(id) { clipboard, protected in
            switch snapshot.strategy {
            case .value, .atoms, .markers:
                applied = try await self.editor.applyAction(answer, to: snapshot, clipboard: clipboard, protected: protected)
            case .copy: try await self.editor.applyByCopy(answer, to: snapshot, clipboard: clipboard, protected: protected)
            }
        }
        return applied
    }

    /// Keeps what a run wrote for as long as its result drop is up (the drop reports its end through `controls.ended`);
    /// nil forgets it.
    func remember(_ record: Written?) {
        written = record
        if record == nil { drop.canRestore = false }
    }

    /// Puts back the span the last run replaced, while the same field holds exactly what it wrote: the drop's undo, and
    /// the wheel's same direction pressed again.
    @discardableResult func restore() -> Task<ActionOutcome, Never>? {
        guard !isBusy, drop.claim(busy: { [weak self] in self?.isBusy == true }) else { return nil }
        let id = UUID(); generation = id
        guard let record = written else {
            let outcome = fail(.nothingToRestore, id, geometry: nil)
            return Task { outcome }
        }
        let run = Task { [weak self] () -> ActionOutcome in
            guard let self else { return .cancelled }
            defer { self.task = nil }
            // A dormant Chromium tree can't be read or written: wake it for the swap, as Fix's restore does.
            let woke = await self.editing.enableAccessibility(record.snapshot)
            let outcome = await self.putBack(record, id)
            if woke { await self.editing.disableAccessibility(record.snapshot) }
            return outcome
        }
        task = run
        return run
    }

    private func putBack(_ record: Written, _ id: UUID) async -> ActionOutcome {
        var snapshot = record.snapshot
        do {
            snapshot = try await editing.restore(snapshot, record.applied, id)
            remember(nil)
            let geometry = await editing.geometry(snapshot.element) ?? snapshot.geometry
            guard generation == id else { return .restored }
            drop.show(.restored, geometry: geometry, element: snapshot.element)
            return .restored
        } catch is CancellationError {
            if generation == id { drop.leave() }
            return .cancelled
        } catch {
            let failure = error is ActionDraftChanged ? ActionFailure.changedSince : ActionFailure(.restore, error.localizedDescription)
            return fail(failure, id, geometry: snapshot.geometry)
        }
    }
}
