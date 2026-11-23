import AppKit
import OopsCore

/// Runs an action on the focused draft, or on its selection: captures it as Fix does, asks the action's model with
/// Actions' own prompt, writes the answer over the whole span through Fix's guarded swap, and shows each step in the
/// drop. One run at a time; a press while one holds the drop does nothing. What a run wrote can be put back while
/// its result shows (`restore()`). An action that runs as an agent goes to `agent`, which runs beside these.
@MainActor final class ActionSession {
    /// Fix's limit (`CorrectionBackend.defaultDeadline`): past it the run fails and writes nothing.
    static let deadline: Duration = .seconds(40)
    let editor: EditorAccess
    let providers: ProviderStore
    let drop: any ActionDrop
    let library: ActionLibraryModel
    /// Reads the focused draft; where the focused field is, without reading its text. The editor's own, or a test's.
    let capture: @MainActor () async throws -> EditorSnapshot
    /// Reads a field only copy and paste reach, the one Accessibility found: never whatever has focus by then.
    private let captureCopy: @MainActor (OpaqueEditor) async throws -> EditorSnapshot
    let locate: @MainActor () async -> CapsulePlacement.Geometry?
    /// Fix forgets the correction it could restore: the draft an action leaves is a new one to Fix.
    var forgetFix: () -> Void = {}
    /// Opens Settings, on Providers when `providers`.
    var openSettings: (_ providers: Bool) -> Void = { _ in }
    /// Whether Settings' Try draft holds the keyboard. A Try run reads nothing unless it does.
    var tryDraftFocused: @MainActor () -> Bool = { false }
    /// The whole draft as the last write left it, for Try to guard its Restore with; nil until a run writes.
    var committed: String?
    /// Repeats a Try run: focuses Try's draft first.
    var retryInTry: (ActionInvocation) -> Void = { _ in }

    var task: Task<ActionOutcome, Never>?
    var generation = UUID()
    /// The swap is under way and can't be cancelled.
    var committing = false
    /// An answer that couldn't be written, for the drop's Copy.
    private(set) var pending: String?
    /// The run the drop's Try again repeats, and why the last one failed (for its Settings button).
    var last: ActionInvocation?
    /// The last run was Settings' Try, so Try again goes back through Try's own draft.
    var lastInTry = false
    private var failure: ActionFailure?
    /// What the last run wrote, while it can be restored.
    struct Written { var snapshot: EditorSnapshot; let applied: String }
    var written: Written?
    var editing = ActionEditing()
    /// The one agent run, and whether its answer is being written through this session's swap.
    let agent: AgentRun
    var agentWriting = false

    #if DEBUG
    /// Debug triggers: how a typed instruction runs, in place of the saved setting, which they never touch.
    var typedRunsWith: ActionRunsWith?
    #else
    let typedRunsWith: ActionRunsWith? = nil
    #endif

    var isBusy: Bool { task != nil || agentWriting }
    var canRestore: Bool { !isBusy && written != nil }

    init(editor: EditorAccess, providers: ProviderStore, drop: any ActionDrop, library: ActionLibraryModel = .shared,
         capture: (@MainActor () async throws -> EditorSnapshot)? = nil,
         captureCopy: (@MainActor (OpaqueEditor) async throws -> EditorSnapshot)? = nil,
         locate: (@MainActor () async -> CapsulePlacement.Geometry?)? = nil, agentDrop: AgentDrop? = nil,
         agentRunner: @escaping @MainActor () throws -> any AgentRunning = { throw ClaudeAgentError.notInstalled }) {
        self.editor = editor; self.providers = providers; self.drop = drop; self.library = library
        let copy = captureCopy ?? { try await editor.captureByCopy($0, action: .actions, selecting: "the text") }
        self.captureCopy = copy
        self.capture = capture ?? {
            do { return try await editor.capture() } catch let opaque as OpaqueEditor {
                try Task.checkCancellation()
                return try await copy(opaque)
            }
        }
        self.locate = locate ?? { try? await editor.focusedGeometry() }
        agent = AgentRun(drop: agentDrop ?? AgentDrop(owner: DropOwner()) { _ in nil }, editor: editor, runner: agentRunner)
        drop.controls = ActionDropControls(
            cancel: { [weak self] in self?.cancel() }, restore: { [weak self] in _ = self?.restore() },
            copy: { [weak self] in self?.copyPending() }, retry: { [weak self] in
                guard let self, let last = self.last else { return }
                if self.lastInTry { self.retryInTry(last) } else { _ = self.run(last) }
            },
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
        agent.session = self
    }

    /// `inTry`: only Settings' Try draft may be read and written, never another app's field. `draft`: the read the
    /// wheel started as it opened, before its field took the keys; let go on every way out but a model run's read.
    @discardableResult func run(_ invocation: ActionInvocation, inTry: Bool = false, draft: PreparedDraft? = nil) -> Task<ActionOutcome, Never>? {
        let runsWith = switch invocation {
        case .saved(let action, _): action.runsWith
        case .typed: typedRunsWith ?? library.library.typed
        }
        if runsWith.kind == .agent {
            // An agent run reads the field itself, once the wheel has given it back its focus: the prepared read goes.
            if let draft { release(draft) }
            return agent.start(invocation, providers.agentRun(runsWith.agent), inTry: inTry)
        }
        guard !isBusy, drop.claim(busy: { [weak self] in self?.isBusy == true }) else {
            if let draft { release(draft) }
            return nil
        }
        forgetFix(); remember(nil); pending = nil; failure = nil; last = invocation; lastInTry = inTry; committed = nil
        let id = UUID(); generation = id
        let run = Task { [weak self] () -> ActionOutcome in
            guard let self else { return .cancelled }
            // A cancelled run keeps the session busy until it has finished, so a run begun meanwhile never meets its cleanup.
            // A prepared draft it never read (a failure before the read) is let go too.
            defer {
                self.task = nil
                if let draft { self.release(draft) }
            }
            return await self.runModel(invocation, runsWith.model, id, inTry ? nil : draft)
        }
        task = run
        return run
    }

    private func runModel(_ invocation: ActionInvocation, _ model: ActionModelRun, _ id: UUID, _ draft: PreparedDraft?) async -> ActionOutcome {
        var woken: EditorSnapshot?
        let outcome = await perform(invocation, model, id, draft, woken: &woken)
        // Capture may have woken a Chromium editor to read it: its switch goes back before the run lets go of the
        // session, so a run begun after this one never has it switched off under it.
        if let woken { await editing.disableAccessibility(woken) }
        return outcome
    }

    private func perform(_ invocation: ActionInvocation, _ model: ActionModelRun, _ id: UUID, _ draft: PreparedDraft?,
                         woken: inout EditorSnapshot?) async -> ActionOutcome {
        var shown: CapsulePlacement.Geometry?
        do {
            // Before anything is read, by capture or by copy: a Try run takes the Try draft or nothing.
            if lastInTry, !tryDraftFocused() { throw ActionFailure(.capture, "Click into the draft, then press Run.") }
            let backend = try providers.actionBackend(model)
            let snapshot: EditorSnapshot
            do { snapshot = try Self.rewritable(await read(draft)) } catch let error where !(error is CancellationError) {
                throw ActionFailure.capture(error)
            }
            shown = snapshot.geometry
            woken = snapshot
            if lastInTry, snapshot.pid != getpid() { throw ActionFailure(.capture, "Click into the draft, then press Run.") }
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
            committed = snapshot.transaction.replacement(answer)
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
            // The answer is in but couldn't be written, so the field is as it was: the drop keeps it to copy.
            drop.show(.held(error.localizedDescription), geometry: nil, element: nil)
            return .held
        }
    }

    /// The draft the wheel read as it opened, or a read now when there is none. A field only copy and paste reach is
    /// read by copy now, which the wheel doesn't start before a run asks for it: the field found then, whose focus the
    /// copy checks, never one that has focus since.
    private func read(_ draft: PreparedDraft?) async throws -> EditorSnapshot {
        guard let draft else { return try await capture() }
        do {
            return try await consume(draft)
        } catch let opaque as OpaqueEditor {
            try Task.checkCancellation()
            return try await captureCopy(opaque)
        }
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
