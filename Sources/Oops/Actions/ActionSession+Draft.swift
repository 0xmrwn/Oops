import AppKit
import OopsCore

/// A read of the focused draft started ahead of its run: the wheel starts it as it opens, before its own field takes
/// the keys, so the run reads the field the person was writing in.
@MainActor final class PreparedDraft {
    private var result: Result<EditorSnapshot, Error>?
    private var reading: Task<Void, Never>?
    /// The read shares a Chromium app's accessibility switch (one hold), from the read until a run reads the draft or
    /// it is let go.
    private(set) var holdsSwitch = false
    /// Let go, or read by a run: the hold is no longer the draft's.
    fileprivate(set) var released = false

    /// `read` answers the draft and whether it took a hold on the app's accessibility switch.
    static func holding(_ read: @escaping @MainActor () async throws -> (EditorSnapshot, Bool)) -> PreparedDraft {
        PreparedDraft(reading: read, holding: ())
    }

    private init(reading read: @escaping @MainActor () async throws -> (EditorSnapshot, Bool), holding _: Void) {
        reading = Task { @MainActor in
            do {
                let (snapshot, held) = try await read()
                self.holdsSwitch = held
                self.result = .success(snapshot)
            } catch {
                self.result = .failure(error)
            }
        }
    }

    /// A read that holds no switch.
    convenience init(_ read: @escaping @MainActor () async throws -> EditorSnapshot) {
        self.init(reading: { (try await read(), false) }, holding: ())
    }

    /// The read has finished, with a draft or an error.
    var isRead: Bool { result != nil }

    func snapshot() async throws -> EditorSnapshot {
        await reading?.value
        guard let result else { throw CancellationError() }
        return try result.get()
    }
}

extension ActionSession {
    /// Starts reading the focused draft now. Only what Accessibility reads: copy and paste waits for a run.
    func prepare() -> PreparedDraft {
        let editor = editor
        return PreparedDraft.holding {
            let snapshot = try await editor.capture()
            return (snapshot, await editor.holdFullAccessibility(for: snapshot))
        }
    }

    /// The draft for the run that reads it: the run owns the switch from now, and puts it back as it ends, as it does
    /// for a draft it read itself.
    func consume(_ draft: PreparedDraft) async throws -> EditorSnapshot {
        let snapshot = try await draft.snapshot()
        if !draft.released, draft.holdsSwitch { _ = await editor.releaseFullAccessibility(for: snapshot) }
        draft.released = true
        return snapshot
    }

    /// Lets go of a prepared draft no run read, on every way out: its hold on the switch goes, and the switch with it
    /// when no one else holds it and no run in Oops is using it (a run puts it back itself as it ends). Once.
    func release(_ draft: PreparedDraft) {
        guard !draft.released else { return }
        draft.released = true
        Task { [weak self] in
            guard let self, draft.holdsSwitch, let snapshot = try? await draft.snapshot(),
                  await self.editor.releaseFullAccessibility(for: snapshot), !self.isBusy, !self.agent.isRunning else { return }
            await self.editing.disableAccessibility(snapshot)
        }
    }
}
