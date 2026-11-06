import AppKit
import OSLog
import OopsCore

/// One correction or revert at a time: capture the draft, ask the provider, validate, swap the text
/// in place, flash the changed words, then show the outcome. The capsule shows each step; Stats, the
/// debug log and the Try page hear about the result. Pressed again on the draft it just corrected, Fix
/// text restores it, then re-applies the fix (D10). Originals stay in memory only, five minutes.
@MainActor final class CorrectionSession {
    static let log = Logger(subsystem: "dev.0xmrwn.oops", category: "Correction")
    let preferences: Preferences
    let testEditor: TestEditorModel
    let capsule = CapsulePanel()
    let editor = EditorAccess()
    let highlight = HighlightOverlay()

    /// Opens Settings (on the Providers page when asked first); Try's own retry; the Try surface in
    /// front, if any (Settings' Try page or onboarding's Try it), which hears how its draft went.
    var openSettings: () -> Void = {}
    var retryInTry: () -> Void = {}
    var activeTry: () -> TestEditorModel? = { nil }

    var task: Task<Void, Never>? { didSet { testEditor.busy = task != nil } }
    private var activeAttempt: Attempt?
    var generation = UUID()
    var committing = false { didSet { testEditor.canCancel = !committing } }
    /// The last correction: the editor that holds it, the attempt it logged, and which text is in the field.
    struct LastCorrection { var snapshot: EditorSnapshot; let attempt: UUID; var toggle: CorrectionToggle }
    var lastCorrection: LastCorrection?
    var forgetting: Task<Void, Never>?
    private var recoveryExpiry: Task<Void, Never>?
    private(set) var originalForRecovery: String?
    var pendingCorrection: String?

    var isBusy: Bool { task != nil }

    init(preferences: Preferences, testEditor: TestEditorModel) {
        self.preferences = preferences
        self.testEditor = testEditor
        capsule.model.cancel = { [weak self] in self?.cancel() }
        capsule.model.revert = { [weak self] in self?.revert() }
        capsule.model.copy = { [weak self] in self?.copyPending() }
        capsule.model.dismiss = { [weak self] in self?.capsule.hide() }
        // The flash never outlives the drop it belongs to.
        capsule.onHide = { [weak self] in self?.highlight.clear() }
        preferences.providers.correctionChanged = { [weak self] in self?.cancel() }
    }

    enum Stage { case capture, provider, apply }

    /// What one correction has learned so far, for its outcome, Stats and the debug log.
    @MainActor final class Attempt {
        let id = UUID()
        let inTryOnly: Bool
        let provider: ProviderCorrection
        /// The Try page, while it is the draft being corrected.
        var fixture: TestEditorModel?
        var stage = Stage.capture
        var snapshot: EditorSnapshot?
        /// What Stats records for a draft in another app; nil for Try's own drafts.
        var counted: (words: Int, app: String, model: String?)?
        /// Logged under the attempt's own id, which a later revert points back to.
        var trace: DebugAttempt
        /// A press on the draft Oops just corrected or restored takes it back or puts it back instead:
        /// nothing is asked or logged for it.
        var press = CorrectionToggle.Press.correct
        var seconds = 0.0
        func checkCurrent(generation: UUID) throws {
            guard generation == id else { throw CancellationError() }
            try provider.checkCurrent()
        }

        func cancelFixture(generation: UUID) {
            guard generation == id else { return }
            fixture?.cancelled()
        }

        init(inTryOnly: Bool, fixture: TestEditorModel?, provider: ProviderCorrection) {
            self.inTryOnly = inTryOnly; self.fixture = fixture; self.provider = provider; trace = DebugAttempt(id: id)
        }
    }

    // MARK: Correct

    /// Corrects the focused draft, takes the last correction back or puts it back (`press(on:)`), or
    /// cancels the running correction. `inTryOnly` is Try's own button, which never corrects another app's draft.
    func correct(inTryOnly: Bool = false) {
        preferences.status = "Correction requested."
        if task != nil { cancel(); return }
        capsule.cancelTimedHide(); pendingCorrection = nil
        // A new correction makes the last one's flash stale.
        highlight.clear()
        Sounds.warm()
        // Claude Code starts its process now, while the draft is read.
        let attempt = Attempt(inTryOnly: inTryOnly, fixture: activeTry(), provider: ProviderCorrection(store: preferences.providers))
        let id = attempt.id; generation = id
        activeAttempt = attempt
        attempt.fixture?.began()
        capsule.model.canRevert = false
        capsule.model.canCancel = true
        task = Task { [weak self] in
            guard let self else { return }
            // Nothing is shown until the editor is read, so the capsule appears where it belongs;
            // only a slow capture (a dormant Teams tree) falls back to the window or screen spot.
            var reveal = self.reveal(after: .milliseconds(400), id) { !$0.capsule.isShown }
            defer {
                reveal.cancel()
                if self.generation == id { self.task = nil }
                if self.activeAttempt === attempt { self.activeAttempt = nil }
            }
            defer { attempt.provider.finish() }
            defer { if attempt.press == .correct { DebugLog.record(attempt.trace) } }
            do {
                let snapshot = try await self.capture(attempt)
                // Before the skips: an unchanged corrected draft is restored, never "Already clear".
                if attempt.press != .correct {
                    reveal.cancel(); self.task = nil
                    if attempt.press == .restore { self.revert() } else { self.reapply() }
                    return
                }
                if let skip = try self.skip(snapshot, provider: attempt.provider) {
                    reveal.cancel()
                    // Capture may have woken a Chromium editor to read it: nothing else will turn that off.
                    await self.editor.disableFullAccessibility(for: snapshot)
                    try attempt.provider.checkCurrent()
                    self.finishSkipped(attempt, geometry: snapshot.geometry, label: skip)
                    return
                }
                // Only for the flash, which a pasted selection never gets.
                let fullAccessibility = snapshot.strategy != .copy ? await self.editor.enableFullAccessibility(for: snapshot) : false
                defer { if fullAccessibility { Task { await self.editor.disableFullAccessibility(for: snapshot) } } }
                try attempt.checkCurrent(generation: self.generation)
                reveal.cancel()
                if self.capsule.isShown { self.capsule.show(.working, label: "Fixing…", geometry: snapshot.geometry) }
                else { self.capsule.show(.invoked, label: "", geometry: snapshot.geometry) }
                self.capsule.follow(snapshot.element) { [weak self, fallback = snapshot.geometry] element in
                    await self?.editor.geometry(of: element) ?? fallback
                }
                reveal = self.reveal(after: .milliseconds(150), id) { $0.capsule.model.phase == .invoked }
                let corrected = try await self.ask(attempt, snapshot)
                guard self.generation == id else { return }
                attempt.stage = .apply
                _ = try snapshot.transaction.validatedReplacement(corrected)
                if sameText(corrected, snapshot.transaction.source) {
                    reveal.cancel()
                    try self.finishClear(attempt)
                    return
                }
                self.pendingCorrection = corrected
                self.preferences.status = "Correction ready. Checking the draft…"
                // The editor the swap ended on: the app may have remounted it after an edit.
                var applied = snapshot, final = corrected
                guard let ms = try await self.swap(id, validate: { try attempt.provider.checkCurrent() }, { clipboard, protected in
                    switch snapshot.strategy {
                    case .value, .atoms, .markers:
                        (applied, final) = try await self.editor.apply(corrected, to: snapshot, clipboard: clipboard, protected: protected)
                    case .copy: try await self.editor.applyByCopy(corrected, to: snapshot, clipboard: clipboard, protected: protected)
                    }
                }) else { return }
                attempt.trace.timings.apply = ms
                guard self.generation == id else { return }
                await self.finishFixed(attempt, applied, final)
            } catch is CancellationError {
                attempt.cancelFixture(generation: self.generation)
                if self.generation == id { self.capsule.hide() }
            } catch let empty as EmptyDraft {
                reveal.cancel()
                guard self.generation == id else { return }
                self.finishSkipped(attempt, geometry: empty.geometry, label: "Nothing to fix", detail: empty.detail)
            } catch let partial as PartialReplacement {
                // Some spans went in: they can still be reverted, and the rest copied.
                if self.pendingCorrection != nil {
                    self.remember(.init(snapshot: partial.snapshot, attempt: id,
                                        toggle: .init(original: partial.snapshot.transaction.before, applied: partial.applied)))
                    self.capsule.model.canRevert = true
                    attempt.trace.applied = partial.applied
                }
                guard self.generation == id else { return }
                await self.fail(attempt, partial)
            } catch {
                guard self.generation == id else { return }
                await self.fail(attempt, error)
            }
        }
    }

    /// Shows "Fixing…" after `delay` unless this correction moved on or `when` no longer holds.
    private func reveal(after delay: Duration, _ id: UUID, when: @escaping (CorrectionSession) -> Bool) -> Task<Void, Never> {
        Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.generation == id, when(self) else { return }
            self.capsule.show(.working, label: "Fixing…")
        }
    }

    private func capture(_ attempt: Attempt) async throws -> EditorSnapshot {
        try attempt.checkCurrent(generation: generation)
        let started = ContinuousClock.now
        let snapshot: EditorSnapshot
        do { snapshot = try await editor.capture() }
        catch let opaque as OpaqueEditor {
            try attempt.checkCurrent(generation: generation)
            snapshot = try await editor.captureByCopy(opaque)
        }
        attempt.snapshot = snapshot
        do {
            try afterCapture(attempt, snapshot, started: started)
            attempt.press = await press(on: snapshot)
            try Task.checkCancellation()
            guard generation == attempt.id else { throw CancellationError() }
        } catch { await editor.disableFullAccessibility(for: snapshot); throw error }
        if attempt.press == .correct { keepOriginal(snapshot.transaction.before) }
        return snapshot
    }

    /// Records the capture; throws when a newer request took over meanwhile.
    private func afterCapture(_ attempt: Attempt, _ snapshot: EditorSnapshot, started: ContinuousClock.Instant) throws {
        attempt.trace.timings.capture = DebugLog.milliseconds(since: started)
        attempt.trace.app = .init(bundleID: snapshot.bundleID, name: snapshot.appName, version: snapshot.appVersion)
        attempt.trace.editor = .init(role: snapshot.role, subrole: snapshot.subrole, capture: snapshot.strategy.rawValue)
        attempt.trace.selection = snapshot.transaction.selection.length > 0
        attempt.trace.draft = snapshot.transaction.before
        attempt.trace.source = snapshot.transaction.source
        try Task.checkCancellation()
        // A newer request took over while the editor was read.
        guard generation == attempt.id else { throw CancellationError() }
        if snapshot.pid != getpid() {
            if attempt.inTryOnly { throw CorrectionError.message("Click into the draft, then press Correct.") }
            attempt.fixture?.cancelled(); attempt.fixture = nil
            attempt.counted = (Stats.words(in: snapshot.transaction.source), snapshot.appName, attempt.provider.modelName)
        }
        attempt.stage = .provider
        // Test runs (a stub provider) leave the real list alone.
        if DebugFlags.stubProvider == nil { AppScope.shared.noteUsed(snapshot.owner) }
    }

    /// The draft as read, for the menu's Copy original draft, five minutes.
    private func keepOriginal(_ original: String) {
        originalForRecovery = original
        preferences.status = "Draft captured. Waiting for correction…"
        recoveryExpiry?.cancel()
        recoveryExpiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(300))
            guard !Task.isCancelled else { return }
            self?.originalForRecovery = nil; self?.pendingCorrection = nil
        }
    }

    /// The provider's answer, decoded and cut down to its safe changes; the raw answer goes to the
    /// debug log first.
    private func ask(_ attempt: Attempt, _ snapshot: EditorSnapshot) async throws -> String {
        attempt.trace.model = attempt.provider.model
        attempt.trace.promptVersion = attempt.provider.promptVersion
        attempt.trace.instructions = attempt.provider.instructions
        let started = ContinuousClock.now
        let raw = try await attempt.provider.complete(snapshot.transaction.source)
        let elapsed = started.duration(to: .now)
        attempt.seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        attempt.trace.timings.provider = DebugLog.milliseconds(since: started)
        attempt.trace.raw = raw
        let transaction = snapshot.transaction
        let reconciled = try CorrectionPolicy.reconcile(raw, original: transaction.source, prefix: transaction.prefix, suffix: transaction.suffix)
        attempt.trace.corrected = reconciled.text
        attempt.trace.dropped = reconciled.dropped.isEmpty ? nil : reconciled.dropped
        attempt.trace.absorbed = reconciled.absorbed == 0 ? nil : reconciled.absorbed
        try Task.checkCancellation()
        return reconciled.text
    }

    /// Why no model needs asking, as the drop says it: nothing but code, links, mentions, paths or
    /// emoji; or the same draft found clear last time, by the same model and prompt.
    private func skip(_ snapshot: EditorSnapshot, provider: ProviderCorrection) throws -> String? {
        try provider.checkCurrent()
        if !CorrectionPolicy.hasProse(snapshot.transaction.source) { return "Nothing to fix" }
        return try provider.isClear(app: snapshot.bundleID, source: snapshot.transaction.source) ? "Already clear" : nil
    }

    func cancel() {
        guard !committing else { return }
        activeAttempt?.cancelFixture(generation: generation)
        preferences.providers.activeCorrection?.cancel()
        generation = UUID(); task?.cancel(); task = nil; activeAttempt = nil; testEditor.cancelled()
        capsule.hide()
    }

    func copyPending() {
        guard let pendingCorrection else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(pendingCorrection, forType: .string)
        if capsule.isShown, capsule.model.phase == .pending { capsule.confirmCopy() } else { capsule.hide() }
    }

    func copyOriginal() {
        guard let originalForRecovery else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(originalForRecovery, forType: .string)
    }

    // MARK: Previews

    /// Debug tools → Placement → Preview: the capsule where the placement engine puts it for the focused editor.
    func previewPlacement() async -> String {
        do {
            let geometry = try await editor.focusedGeometry()
            preview(geometry: geometry)
            if let placement = capsule.placement { PlacementProbe.recordPreview(geometry, placement) }
            return "Placed by \(capsule.placement?.strategy.rawValue ?? "unknown") strategy."
        } catch { return error.localizedDescription }
    }

    /// Debug tools → Capsule → Play: the busy and done animation, without sending any text.
    func preview(geometry: CapsulePlacement.Geometry? = nil) {
        Sounds.warm()
        capsule.show(.invoked, label: "", geometry: geometry)
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            self?.capsule.show(.working, label: "Fixing…")
            try? await Task.sleep(for: .seconds(DebugFlags.previewWorkingSeconds > 0 ? DebugFlags.previewWorkingSeconds : 1.7))
            let outcome = DebugFlags.previewOutcome
            switch outcome {
            case "failed":
                // Retry replays the preview, reading the outcome again.
                self?.capsule.model.retry = { [weak self] in self?.preview(geometry: geometry) }
                self?.capsule.show(.failed, label: "No connection", detail: "Preview of the failure state.", remedy: .retry)
            case "clear": self?.capsule.show(.fixed, label: "Already clear · 0.6s")
            case "pending":
                self?.pendingCorrection = "Preview correction"
                self?.capsule.show(.pending, label: "Couldn’t paste", detail: "Preview of the copy fallback.")
                return
            case "reverted":
                self?.capsule.show(.fixed, label: "3 fixes · 0.8s")
                try? await Task.sleep(for: .seconds(1.4))
                self?.capsule.show(.reverted, label: "Reverted")
            default: self?.capsule.show(.fixed, label: "3 fixes · 0.8s")
            }
            self?.capsule.hide(after: outcome == "failed" ? 8 : 1.5)
        }
    }

    #if DEBUG
    /// Launch-argument stills for captures: a failure or the copy fallback, without a correction.
    func previewFailure() {
        capsule.show(.failed, label: "No connection", detail: "Preview error. Your draft was left unchanged.", remedy: .retry)
        capsule.hide(after: 8)
    }

    func previewPending() {
        pendingCorrection = "Preview correction"
        capsule.show(.pending, label: "Couldn’t paste")
    }
    #endif
}
