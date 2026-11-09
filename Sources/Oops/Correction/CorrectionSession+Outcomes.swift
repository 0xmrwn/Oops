import AppKit
import OSLog
import OopsCore

/// How a correction ends: skipped, already clear, fixed (with its flash) or failed, as the capsule,
/// Stats, the debug log and Try hear it.
extension CorrectionSession {
    func finishSkipped(_ attempt: Attempt, geometry: CapsulePlacement.Geometry, label: String, detail: String = "") {
        attempt.fixture?.alreadyClear(seconds: 0)
        attempt.trace.outcome = .skipped
        attempt.trace.reason = detail.isEmpty ? label : label + ". " + detail
        capsule.show(.fixed, label: label, detail: detail, spoken: detail.isEmpty ? label : label + ". " + detail, geometry: geometry)
        capsule.hide(after: 1.1)
    }

    func finishClear(_ attempt: Attempt) throws {
        if let snapshot = attempt.snapshot { try attempt.provider.rememberClear(app: snapshot.bundleID, source: snapshot.transaction.source) }
        if let counted = attempt.counted {
            Stats.shared.record(.init(date: .now, outcome: .clear, words: counted.words, seconds: attempt.seconds,
                                      model: counted.model, app: counted.app))
        }
        attempt.fixture?.alreadyClear(seconds: attempt.seconds)
        attempt.trace.outcome = .clear
        capsule.show(.fixed, label: "Already clear · " + TestEditorModel.seconds(attempt.seconds),
                     spoken: "Already clear in " + Self.spoken(attempt.seconds))
        capsule.hide(after: 1.1)
    }

    func finishFixed(_ attempt: Attempt, _ snapshot: EditorSnapshot, _ corrected: String) async {
        let id = attempt.id, seconds = attempt.seconds
        pendingCorrection = nil
        let appliedAt = Date()
        let diff = WordDiff(before: snapshot.transaction.source, after: corrected)
        let applied = snapshot.transaction.replacement(corrected)
        attempt.trace.applied = applied
        attempt.trace.fixes = diff.changes
        attempt.trace.outcome = .fixed
        if let counted = attempt.counted {
            Stats.shared.record(.init(date: appliedAt, outcome: .fixed, words: counted.words, fixes: diff.changes,
                                      seconds: seconds, model: counted.model, app: counted.app))
        }
        // A pasted selection can't be confirmed or found again: no revert, no flash.
        let revertible = snapshot.strategy != .copy
        remember(revertible ? .init(snapshot: snapshot, attempt: id, toggle: .init(original: snapshot.transaction.before,
                                                                                  applied: applied, date: appliedAt)) : nil)
        if let fixture = attempt.fixture {
            fixture.corrected(before: snapshot.transaction.before, expected: applied, seconds: seconds)
        } else { testEditor.restoreUnavailable() }
        capsule.model.canRevert = revertible
        if revertible {
            let highlightStart = ContinuousClock.now
            await flashHighlights(diff.afterRanges, in: snapshot, holding: applied,
                                  offset: snapshot.transaction.range.location, style: .correction,
                                  remounted: attempt.snapshot.map { !CFEqual($0.element, snapshot.element) } ?? false)
            attempt.trace.timings.highlight = DebugLog.milliseconds(since: highlightStart)
        }
        // The replacement can reflow the composer (its height follows the text), and the app may have remounted it:
        // the capsule tracks the editor that holds the draft now.
        let current = await editor.following(snapshot, holding: applied)
        let geometry = await editor.geometry(of: current.element) ?? current.geometry
        if generation == id { capsule.follow(current.element) { [weak self] element in await self?.editor.geometry(of: element) ?? geometry } }
        guard generation == id else { return }
        let undo = Shortcut.undoHint(ShortcutSettings.shared.shortcut(.correct))
        capsule.show(.fixed, label: TestEditorModel.fixesLabel(diff.changes) + " · " + TestEditorModel.seconds(seconds),
                     detail: revertible ? undo : "",
                     spoken: TestEditorModel.fixesLabel(diff.changes) + " in " + Self.spoken(seconds), geometry: geometry)
        preferences.status = revertible ? "Correction applied. \(undo) while the draft is unchanged." : "Correction applied."
        capsule.hide(after: ResultTiming.seconds)
    }

    func fail(_ attempt: Attempt, _ error: Error) async {
        let message = error.localizedDescription, stage = attempt.stage
        attempt.trace.outcome = pendingCorrection != nil ? .pending : .failed
        attempt.trace.failedStage = switch stage { case .capture: .capture; case .provider: .provider; case .apply: .apply }
        attempt.trace.error = message
        attempt.trace.reason = (error as? CorrectionError)?.reason.map { String(describing: $0) }
        if attempt.trace.app == nil, let front = NSWorkspace.shared.frontmostApplication {
            attempt.trace.app = .init(bundleID: front.bundleIdentifier, name: front.localizedName ?? "", version: nil)
        }
        if let counted = attempt.counted {
            Stats.shared.record(.init(date: .now, outcome: .failed, words: counted.words, model: counted.model, app: counted.app))
        }
        // The message names the check that failed; it never carries the draft.
        Self.log.notice("correction_failed stage=\(String(describing: stage), privacy: .public) reason=\(message, privacy: .public)")
        attempt.fixture?.failed(message, remedy: stage == .provider ? .settings
                                : (stage == .capture && !AccessibilityPermission.granted ? .accessibility : nil))
        if pendingCorrection != nil {
            capsule.show(.pending, label: "Couldn’t paste", detail: message)
        } else {
            let failure = Self.failure(error, at: stage)
            capsule.model.retry = attempt.inTryOnly ? { [weak self] in self?.retryInTry() } : { [weak self] in self?.correct() }
            let providers = stage == .provider
            capsule.model.openSettings = { [weak self] in
                if providers { self?.preferences.providers.wantsProvidersPage = true }
                self?.openSettings()
            }
            capsule.show(.failed, label: failure.label, detail: message, remedy: failure.remedy)
        }
        if let snapshot = attempt.snapshot, await !editor.isInFront(snapshot), generation == attempt.id { capsule.unanchor() }
        guard generation == attempt.id, !Task.isCancelled else { return }
        preferences.status = message
        if pendingCorrection == nil { capsule.hide(after: 8) }
    }

    /// A few words for the drop and what would help, from the error's reason or the stage that stopped.
    /// The full message stays in the drop's tooltip and Settings.
    static func failure(_ error: Error, at stage: Stage) -> (label: String, remedy: CapsuleModel.Remedy?) {
        if (error as? CorrectionError)?.reason == .tooLong { return ("Too long", nil) }
        if stage == .capture { return AccessibilityPermission.granted ? ("Can’t edit here", nil) : ("Not allowed", .settings) }
        return switch (error as? CorrectionError)?.reason {
        case .offline: ("No connection", .retry)
        case .slow: ("Took too long", .retry)
        case .signIn: ("Signed out", .settings)
        case .limit: ("Limit reached", .settings)
        case .setup: ("Check provider", .settings)
        case .tooLong: ("Too long", nil)
        case .empty: ("Nothing to fix", nil)
        case nil: ("Couldn’t correct", .retry)
        }
    }

    static func spoken(_ seconds: Double) -> String { String(format: "%.1f seconds", seconds) }
}
