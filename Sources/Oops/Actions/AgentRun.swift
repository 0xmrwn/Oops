import AppKit
import OopsCore

/// An action that runs as an agent: Claude Code with a few tools, for up to five minutes, while the person may move
/// on. Its status shows at the caret while they stay in the draft's field; away, the drop is free for Fix, Dictate and
/// model actions, and the menu bar shows the run. Finished in the field, the answer replaces the draft like a slow
/// Fix; finished elsewhere, it waits as a ready result until it is taken back to its draft or dismissed. One run at a
/// time; the held answer lives in memory only.
@MainActor final class AgentRun {
    private(set) var flow = AgentRunFlow()
    /// The action's name and symbol, for the drop and the menu.
    private(set) var name = "", symbol = "sparkles"
    weak var session: ActionSession?
    let drop: AgentDrop
    private let makeRunner: @MainActor () throws -> any AgentRunning
    private let watch: AgentFocusWatch
    /// Whether the field read at capture has focus now; called off the main thread.
    private let holdsFocus: @Sendable (EditorSnapshot) -> Bool
    var snapshot: EditorSnapshot?
    /// What the run was started with, and whether from Settings' Try, whose draft alone a retry may read.
    private(set) var invocation: ActionInvocation?
    private(set) var inTry = false
    /// The answer, from the moment it arrives until it is written, offered to copy or dismissed.
    var held: String?
    /// An answer that couldn't be written, for the drop's Copy.
    var copyable: String?
    /// What the run wrote, for the done drop's undo.
    var kept: ActionSession.Written?
    private var failure: ActionFailure?
    /// From the press until the draft is read: the drop is held, and the run can be cancelled, before it has a phase.
    private var starting = false
    private(set) var elapsed = Duration.zero
    /// How the run is getting on, from its start: what its drop and the menu say while it works.
    var progress: AgentProgress?
    /// The action whose recent times the run's own joins once it answers: none for typed instructions.
    var timedAs: UUID?
    /// Answered runs' times, for the opening's sense of how long the action takes.
    let history: AgentRunHistory
    /// The working drop's words now, and the one wake that changes them when no update does.
    var shown = ""
    var wake: (at: ContinuousClock.Instant, task: Task<Void, Never>)?
    private var task: Task<ActionOutcome, Never>?
    /// The write the run ends with, which the run's own task waits for.
    private var finishing: Task<ActionOutcome, Never>?
    /// The ready result has been announced once, with its sound.
    private var announced = false
    /// The run's task waits here while its result is ready, so whoever started it (Try) hears how it ended: written,
    /// held to copy, or dismissed.
    var waiting: CheckedContinuation<ActionOutcome, Never>?
    var readyResult: ActionOutcome?
    /// The run holds a Chromium app's accessibility switch from its capture until it ends.
    private var heldSwitch: EditorSnapshot?
    /// Whether Fix or a model action is at work, so a Chromium switch this run held is left on for them.
    var othersBusy: () -> Bool = { false }
    /// Sounds the run plays itself, when another feature holds the drop.
    var cue: (SoundCue) -> Void = { Sounds.play($0, after: 0) }
    /// Says in the status line why a request couldn't be done now.
    var refused: (String) -> Void = { _ in }
    /// While the done drop's Undo hands the write to Actions' restore, the drop's end mustn't forget it.
    var restoring = false
    /// Escape is armed for a while each time the working drop comes up, never for the whole of a long run: the
    /// field's own app gets its Escape back, and the drop's tap and the menu still cancel.
    static let escapeHold: Duration = .seconds(30)
    private var armed = false, wasWorking = false, escapeUntil = ContinuousClock.now
    private var escapeExpiry: Task<Void, Never>?
    /// The menu bar shows the run's state.
    var changed: () -> Void = {}
    /// Plain Escape cancels while the run's working drop is in front, and only then.
    var escape: (Bool) -> Void = { _ in }
    #if DEBUG
    /// Every change of phase, field or drop, for agent.jsonl.
    var onEvent: (([String: String]) -> Void)?
    #endif

    init(drop: AgentDrop, editor: EditorAccess, runner: @escaping @MainActor () throws -> any AgentRunning,
         holdsFocus: (@Sendable (EditorSnapshot) -> Bool)? = nil, history: AgentRunHistory = AgentRunHistory()) {
        self.drop = drop; makeRunner = runner; self.history = history
        let holds = holdsFocus ?? { editor.holdsFocus($0) }
        self.holdsFocus = holds
        watch = AgentFocusWatch(holds: holds)
        watch.changed = { [weak self] in self?.handle(.focus($0)) }
        drop.busy = { [weak self] in self.map { $0.starting || $0.flow.phase == .running && $0.flow.inField } ?? false }
        drop.cancel = { [weak self] in self?.cancel() }
        drop.open = { [weak self] in self?.act() }
        drop.discard = { [weak self] in self?.dismiss() }
        drop.copy = { [weak self] in self?.copy() }
        drop.restore = { [weak self] in self?.restore() }
        drop.retry = { [weak self] in self?.retry() }
        drop.released = { [weak self] in self?.dropEnded() }
        drop.openSettings = { [weak self] in self?.session?.openSettings(self?.failure?.reason != .capture) }
        drop.changed = { [weak self] in self?.report() }
        drop.idle = { [weak self] in self?.handle(.dropFree) }
    }

    var isReady: Bool { flow.phase == .ready }
    var isRunning: Bool { starting || flow.phase == .running }
    /// What the run is doing, for the menu: the status its drop shows, without the action's name.
    var stepLabel: String { progress?.status(at: .now).label ?? flow.step.label }

    /// Starts `invocation` as an agent run on the focused draft, or refuses while another run is under way or ready.
    func start(_ invocation: ActionInvocation, _ run: ActionAgentRun, inTry: Bool) -> Task<ActionOutcome, Never>? {
        guard let session else { return nil }
        guard flow.canStart, !starting, task == nil else { return session.refuseAgent(.agentBusy(name), invocation, inTry: inTry) }
        guard drop.claim() else { return nil }
        starting = true
        self.invocation = invocation
        name = ActionSession.name(invocation)
        symbol = if case let .saved(action, _) = invocation { action.symbol } else { "sparkles" }
        self.inTry = inTry
        held = nil; copyable = nil; kept = nil; failure = nil; snapshot = nil; finishing = nil; announced = false; readyResult = nil
        progress = nil; drop.startedAt = nil
        session.forgetFix()
        let task = Task { [weak self] () -> ActionOutcome in
            guard let self else { return .cancelled }
            defer { self.task = nil }
            return await self.perform(invocation, run, inTry: inTry)
        }
        self.task = task
        report()
        return task
    }

    private func perform(_ invocation: ActionInvocation, _ run: ActionAgentRun, inTry: Bool) async -> ActionOutcome {
        guard let session else { return .cancelled }
        defer { watch.stop() }
        do {
            // Before anything is read: a Try run takes the Try draft or nothing, and nothing runs without Claude Code.
            if inTry, !session.tryDraftFocused() { throw ActionFailure(.capture, "Click into the draft, then press Run.") }
            let runner: any AgentRunning
            do { runner = try makeRunner() } catch { throw ActionFailure.agent(error) }
            let snapshot: EditorSnapshot
            do { snapshot = try ActionSession.rewritable(await session.capture()) } catch let error where !(error is CancellationError) {
                throw ActionFailure.capture(error)
            }
            self.snapshot = snapshot
            // Capture may have switched on a Chromium app's accessibility: the run shares it until it ends.
            if await session.editor.holdFullAccessibility(for: snapshot) { heldSwitch = snapshot }
            if inTry, snapshot.pid != getpid() { throw ActionFailure(.capture, "Click into the draft, then press Run.") }
            try Task.checkCancellation()
            let source = snapshot.transaction.source, request = ActionPrompt.request(for: invocation, draft: source)
            let started = ContinuousClock.now
            let timed: UUID? = if case let .saved(action, _) = invocation { action.id } else { nil }
            begin(timed, at: started)
            starting = false
            handle(.started)
            watch.start(snapshot)
            var raw: String?
            do {
                for try await update in runner.run(ClaudeAgentRequest(run: run, instructions: request.instructions, input: request.input)) {
                    heard(update)
                    switch update {
                    case let .step(step): handle(.step(step))
                    case let .answer(answer): raw = answer
                    case .activity, .summary: break
                    }
                }
            } catch let error where !(error is CancellationError) { throw ActionFailure.agent(error) }
            try Task.checkCancellation()
            guard let raw else { throw ActionFailure.agent(ClaudeAgentError.stopped) }
            do { held = try ActionPrompt.decode(raw, draft: source) } catch { throw ActionFailure.agent(error) }
            elapsed = started.duration(to: .now)
            watch.stop()
            // Checked now rather than taken from the last sample: the person may have just left, or just come back.
            let holds = holdsFocus
            handle(.focus(await Task.detached { holds(snapshot) }.value))
            try Task.checkCancellation()
            keepTime()
            handle(.answered)
            if flow.phase == .ready {
                await settle()
                return await readyOutcome()
            }
            let outcome = await finishing?.value ?? .held
            await settle()
            return outcome
        } catch is CancellationError {
            starting = false
            await settle()
            return .cancelled
        } catch {
            // Cancelled while the draft was read: nothing more to say.
            if Task.isCancelled { await settle(); return .cancelled }
            let failure = error as? ActionFailure ?? .agent(error)
            self.failure = failure
            if flow.phase == .running { handle(.failed) } else {
                // Before the run had begun: the failure shows at the caret the press came from, as a model run's does.
                starting = false
                drop.yield()
                _ = await session.refuseAgent(failure, invocation, inTry: inTry, geometry: snapshot?.geometry)?.value
            }
            await settle()
            return .failed(failure)
        }
    }

    /// Capture may have woken a Chromium editor to read it: its switch goes back once the run no longer needs it, and
    /// no one else does. Fix or a model action at work in the same app turns it off itself as it ends; failing that it
    /// goes once they are done. A return to the draft wakes it again for as long as it takes.
    private func settle() async {
        guard let snapshot = heldSwitch, let session else { return }
        heldSwitch = nil
        guard await session.editor.releaseFullAccessibility(for: snapshot) else { return }
        let others = othersBusy, editing = session.editing
        Task {
            while others() { try? await Task.sleep(for: .milliseconds(500)) }
            await editing.disableAccessibility(snapshot)
        }
    }

    /// The drop's tap, Escape while it is in front, or the menu's Cancel.
    func cancel() {
        if starting {
            starting = false
            task?.cancel()
            drop.yield()
            return report()
        }
        guard flow.phase == .running else { return }
        task?.cancel()
        handle(.cancelled)
    }

    func handle(_ event: AgentRunFlow.Event) {
        let before = flow, effects = flow.handle(event)
        guard !effects.isEmpty || flow != before else { return }
        for effect in effects {
            switch effect {
            // The run's progress, not the bare step: it holds each label long enough to read.
            case .showStatus: showProgress()
            case .yieldDrop: drop.yield()
            case .menu: break
            case .writeInPlace: finishing = Task { await self.writeInPlace() }
            case .announceReady: Task { await self.announceReady() }
            case let .showFailure(here): Task { await self.showFailure(here: here) }
            case .returnToDraft:
                finishing = Task {
                    let outcome = await self.returnToDraft()
                    self.resolve(outcome)
                    return outcome
                }
            case .discard:
                held = nil
                resolve(.cancelled)
            }
        }
        if flow.phase != .running { stopWaking() }
        report()
    }

    /// The menu, the Escape hotkey and the lab log follow the run.
    func report() {
        let working = flow.phase == .running && drop.working
        if working, !wasWorking {
            escapeUntil = .now + Self.escapeHold
            escapeExpiry?.cancel()
            escapeExpiry = Task { [weak self] in
                try? await Task.sleep(for: Self.escapeHold)
                if !Task.isCancelled { self?.report() }
            }
        }
        wasWorking = working
        let arm = working && ContinuousClock.now < escapeUntil
        if arm != armed { armed = arm; escape(arm) }
        changed()
        #if DEBUG
        var entry = ["phase": String(describing: flow.phase), "inField": flow.inField ? "yes" : "no", "step": flow.step.label,
                     "mark": String(describing: flow.mark)]
        entry.merge(drop.state) { a, _ in a }
        onEvent?(entry)
        #endif
    }

    private func announceReady() async {
        guard flow.phase == .ready else { return }
        let geometry = await session?.locate()
        guard flow.phase == .ready, !drop.inFront else { return }
        // Another feature holds the drop: the sound alone says it's ready, once, and the drop follows when it's free.
        if !drop.showReady(name, geometry: geometry, cue: !announced), !announced { cue(.success) }
        announced = true
    }

    private func showFailure(here: Bool) async {
        guard let failure else { return }
        let geometry = here ? await session?.locate() : snapshot?.geometry
        if !drop.showFailure(failure, geometry: geometry) { cue(.failure) }
    }
}
