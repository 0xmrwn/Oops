import AppKit
import OopsCore

/// Runs an action on the focused draft, or on its selection: captures it as Fix does, asks the action's model with
/// Actions' own prompt, writes the answer over the whole span through Fix's guarded swap, and shows each step in the
/// drop. One run at a time; a press while one holds the drop does nothing. What a run wrote can be put back while
/// its result shows (`restore()`).
@MainActor final class ActionSession {
    /// Fix's limit (`CorrectionBackend.defaultDeadline`): past it the run fails and writes nothing.
    static let deadline: Duration = .seconds(40)
    let editor: EditorAccess
    let providers: ProviderStore
    let drop: any ActionDrop
    let library: ActionLibraryModel
    /// Reads the focused draft; where the focused field is, without reading its text. The editor's own, or a test's.
    private let capture: @MainActor () async throws -> EditorSnapshot
    let locate: @MainActor () async -> CapsulePlacement.Geometry?
    /// Fix forgets the correction it could restore: the draft an action leaves is a new one to Fix.
    var forgetFix: () -> Void = {}
    /// Opens Settings, on Providers when `providers`.
    var openSettings: (_ providers: Bool) -> Void = { _ in }

    var task: Task<ActionOutcome, Never>?
    var generation = UUID()
    /// The swap is under way and can't be cancelled.
    var committing = false
    /// An answer that couldn't be written, for the drop's Copy.
    private(set) var pending: String?
    /// The run the drop's Try again repeats, and why the last one failed (for its Settings button).
    private(set) var last: ActionInvocation?
    private var failure: ActionFailure?
    /// What the last run wrote, while it can be restored.
    struct Written { var snapshot: EditorSnapshot; let applied: String }
    var written: Written?
    var editing = ActionEditing()

    var isBusy: Bool { task != nil }
    var canRestore: Bool { !isBusy && written != nil }

    init(editor: EditorAccess, providers: ProviderStore, drop: any ActionDrop, library: ActionLibraryModel = .shared,
         capture: (@MainActor () async throws -> EditorSnapshot)? = nil,
         locate: (@MainActor () async -> CapsulePlacement.Geometry?)? = nil) {
        self.editor = editor; self.providers = providers; self.drop = drop; self.library = library
        self.capture = capture ?? {
            do { return try await editor.capture() } catch let opaque as OpaqueEditor {
                try Task.checkCancellation()
                return try await editor.captureByCopy(opaque, action: .actions, selecting: "the text")
            }
        }
        self.locate = locate ?? { try? await editor.focusedGeometry() }
        drop.controls = ActionDropControls(
            cancel: { [weak self] in self?.cancel() }, restore: { [weak self] in _ = self?.restore() },
            copy: { [weak self] in self?.copyPending() }, retry: { [weak self] in _ = self?.last.flatMap { self?.run($0) } },
            openSettings: { [weak self] in self?.openSettings(self?.failure?.reason != .capture) },
            ended: { [weak self] in self?.written = nil })
        editing = ActionEditing(
            write: { [weak self] answer, snapshot, id in
                guard let self else { throw CancellationError() }
                return try await self.write(answer, over: snapshot, id)
            },
            restore: { [weak self] snapshot, applied, id in
                guard let self else { throw CancellationError() }
                var restored = snapshot
                try await self.swap(id) { clipboard, protected in
                    restored = try await editor.restoreAction(snapshot, from: applied, clipboard: clipboard, protected: protected)
                }
                return restored
            },
            geometry: { await editor.geometry(of: $0) },
            enableAccessibility: { await editor.enableFullAccessibility(for: $0) },
            disableAccessibility: { await editor.disableFullAccessibility(for: $0) })
    }

    /// The Actions shortcut. Until the wheel exists it runs the action at the top place, with its choice's first value.
    @discardableResult func pressed() -> Task<ActionOutcome, Never>? {
        guard !isBusy, let action = library.library.action(at: .up) else { return nil }
        return run(.saved(action, value: action.choice?.ordered.first))
    }

    @discardableResult func run(_ invocation: ActionInvocation) -> Task<ActionOutcome, Never>? {
        guard !isBusy, drop.claim(busy: { [weak self] in self?.isBusy == true }) else { return nil }
        forgetFix(); remember(nil); pending = nil; failure = nil; last = invocation
        let runsWith = switch invocation {
        case .saved(let action, _): action.runsWith
        case .typed: library.library.typed
        }
        let id = UUID(); generation = id
        let run = Task { [weak self] () -> ActionOutcome in
            guard let self else { return .cancelled }
            // A cancelled run keeps the session busy until it has finished, so a run begun meanwhile never meets its cleanup.
            defer { self.task = nil }
            // Agent runs come later: long, in the background and cancellable, they get a run of their own beside
            // `runModel`, sharing capture, write and restore.
            switch runsWith.kind {
            case .model: return await self.runModel(invocation, runsWith.model, id)
            case .agent:
                let geometry = await self.locate()
                return self.fail(.agentRun, id, geometry: geometry)
            }
        }
        task = run
        return run
    }

    private func runModel(_ invocation: ActionInvocation, _ model: ActionModelRun, _ id: UUID) async -> ActionOutcome {
        var woken: EditorSnapshot?
        let outcome = await perform(invocation, model, id, woken: &woken)
        // Capture may have woken a Chromium editor to read it: its switch goes back before the run lets go of the
        // session, so a run begun after this one never has it switched off under it.
        if let woken { await editing.disableAccessibility(woken) }
        return outcome
    }

    private func perform(_ invocation: ActionInvocation, _ model: ActionModelRun, _ id: UUID,
                         woken: inout EditorSnapshot?) async -> ActionOutcome {
        var shown: CapsulePlacement.Geometry?
        do {
            let backend = try providers.actionBackend(model)
            let snapshot: EditorSnapshot
            do { snapshot = try await capture() } catch let error where !(error is CancellationError) { throw ActionFailure.capture(error) }
            shown = snapshot.geometry
            woken = snapshot
            try checkCurrent(id)
            let name = Self.name(invocation), source = snapshot.transaction.source
            drop.show(.working(name), geometry: snapshot.geometry, element: snapshot.element)
            let started = ContinuousClock.now
            let answer: String
            do { answer = try await Self.answer(ActionPrompt.request(for: invocation, draft: source), draft: source, from: backend, deadline: Self.deadline) }
            catch let error where !(error is CancellationError) { throw ActionFailure.model(error) }
            let elapsed = started.duration(to: .now)
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            try checkCurrent(id)
            pending = answer
            let applied = try await editing.write(answer, snapshot, id)
            pending = nil
            let restorable = snapshot.strategy != .copy
            if restorable { remember(.init(snapshot: applied, applied: snapshot.transaction.replacement(answer))) }
            let geometry = await editing.geometry(applied.element) ?? snapshot.geometry
            // A cancel during the lookup ended this run: its drop is no longer this run's to change.
            guard generation == id else { return .written }
            drop.show(.done(name, seconds: seconds, canRestore: restorable), geometry: geometry, element: applied.element)
            return .written
        } catch is CancellationError {
            if generation == id { drop.leave() }
            return .cancelled
        } catch let failure as ActionFailure {
            let geometry = if let shown { shown } else { await locate() }
            return fail(failure, id, geometry: geometry)
        } catch {
            guard pending != nil else { return fail(.model(error), id, geometry: shown) }
            guard generation == id else { return .cancelled }
            if let partial = error as? PartialReplacement { return await takeBack(partial, id) }
            // The answer is in but couldn't be written, so the field is as it was: the drop keeps it to copy.
            drop.show(.held(error.localizedDescription), geometry: nil, element: nil)
            return .held
        }
    }

    /// A partial write left part of the draft changed: the original goes back at once, through the guarded restore, so
    /// the held answer is true to say "not written". When it can't, the drop says the draft was changed in part.
    private func takeBack(_ partial: PartialReplacement, _ id: UUID) async -> ActionOutcome {
        // Past the point of cancelling: stopping now would leave the draft as it is.
        committing = true; drop.canCancel = false
        defer { committing = false; drop.canCancel = true }
        do {
            _ = try await editing.restore(partial.snapshot, partial.applied, id)
        } catch {
            return fail(.partlyWritten, id, geometry: nil)
        }
        guard generation == id else { return .cancelled }
        drop.show(.held("The editor didn’t confirm every change, so the draft was put back as it was. The answer is ready to copy."),
                  geometry: nil, element: nil)
        return .held
    }

    /// The model's replacement for `draft`: Actions' own prompt, ended at `deadline` whatever the backend does, decoded.
    nonisolated static func answer(_ request: ActionRequest, draft: String, from backend: any CorrectionBackend,
                                   deadline: Duration) async throws -> String {
        let raw = try await withDeadline(deadline, orThrow: ActionFailure.slow) {
            try await backend.complete(request.input, instructions: request.instructions, deadline: deadline)
        }
        return try ActionPrompt.decode(raw, draft: draft)
    }

    func fail(_ failure: ActionFailure, _ id: UUID, geometry: CapsulePlacement.Geometry?) -> ActionOutcome {
        guard generation == id else { return .cancelled }
        self.failure = failure
        drop.show(.failed(failure), geometry: geometry, element: nil)
        return .failed(failure)
    }

    func checkCurrent(_ id: UUID) throws {
        try Task.checkCancellation()
        guard generation == id else { throw CancellationError() }
    }

    /// The drop's tap while working; refused once the swap has started.
    func cancel() {
        guard !committing else { return }
        generation = UUID(); task?.cancel()
        drop.leave()
    }

    func copyPending() {
        guard let pending else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(pending, forType: .string)
    }

    static func name(_ invocation: ActionInvocation) -> String {
        switch invocation {
        case .saved(let action, _): action.name
        case .typed: "Action"
        }
    }
}
