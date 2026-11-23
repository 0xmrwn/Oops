import Foundation
import OopsCore

/// What a working agent run says, from its progress: the drop at the caret and the menu follow the status as each
/// update arrives, and again at the moments it changes on its own, with one wake scheduled at a time and no polling.
extension AgentRun {
    /// Written while the person watches: in the field, or once the run is back in its draft.
    static let placing = "Putting it in place"
    /// The most of a summary the done drop shows before the time.
    static let summaryLength = 48

    /// The run has begun at `time`: its progress expects what `action`'s recent runs took, and the drop's timer counts
    /// from now for the rest of the run, however often another feature takes the drop meanwhile.
    func begin(_ action: UUID?, at time: ContinuousClock.Instant = .now) {
        progress = AgentProgress(start: time, usual: action.map { history.durations(for: $0) } ?? [])
        timedAs = action
        shown = ""
        drop.startedAt = Date(); drop.heard = nil
    }

    /// An update from the agent, as it arrives. An answer's time is noted here but kept only by `keepTime()`.
    func heard(_ update: ClaudeAgentUpdate, at time: ContinuousClock.Instant = .now) {
        guard progress != nil else { return }
        progress?.handle(update, at: time)
        // Every update, as every update keeps the progress from calming: the drop's light and the label agree.
        drop.activity()
        refresh(at: time)
    }

    /// The run's answer was usable and the run wasn't cancelled: its time joins the action's history. An answer that
    /// couldn't be read says nothing about how long the action takes.
    func keepTime() {
        guard let progress, let timedAs else { return }
        history.record(progress, for: timedAs)
    }

    /// Shows the status at `time` where it changed, and wakes again when it next changes by itself.
    func refresh(at time: ContinuousClock.Instant = .now) {
        guard flow.phase == .running, let progress else { return stopWaking() }
        let label = Self.label(progress.status(at: time), name: name)
        if label != shown {
            shown = label
            // At the caret only while the run holds the drop; parked, the pill keeps the words for the pointer.
            if flow.holdsDrop { show(label) } else if flow.place == .parked { drop.parkedStatus(label) }
            report()
        }
        schedule(progress.nextChange(after: time))
    }

    /// The run's drop at the caret, or `parked` in the pill, saying what the run is doing now.
    /// Wakes for the status's next change from here too: an opening note must go on time even if no update comes.
    func showProgress(parked: Bool = false) {
        let now = ContinuousClock.now
        shown = progress.map { Self.label($0.status(at: now), name: name) } ?? name
        if parked { drop.park(shown) } else { show(shown) }
        if flow.phase == .running, let progress { schedule(progress.nextChange(after: now)) }
    }

    func stopWaking() {
        wake?.task.cancel()
        wake = nil
    }

    private func show(_ label: String) {
        guard let snapshot else { return }
        drop.showStatus(label, element: snapshot.element, fallback: snapshot.geometry)
    }

    private func schedule(_ next: ContinuousClock.Instant?) {
        guard next != wake?.at else { return }
        wake?.task.cancel()
        wake = next.map { at in
            (at, Task { [weak self] in
                try? await Task.sleep(until: at, clock: .continuous)
                guard !Task.isCancelled, let self else { return }
                wake = nil
                refresh()
            })
        }
    }

    /// The working drop's words for `status`: the action's name as the run starts, with how long it usually takes
    /// when that is known, then what it is doing. Nothing adds an ellipsis: the ring, the light and the timer already
    /// say it is at work, and only words that are cut or still going ("Still working…") end in one.
    static func label(_ status: AgentProgress.Status, name: String) -> String {
        if let note = status.note, status.elapsed < AgentProgress.opening { return name + " · " + note }
        return status.step == .starting && status.note == nil ? name : status.label
    }

    /// The done drop's words: what the run did, when Claude Code said, else the action's name; then the time.
    static func done(_ name: String, summary: String?, elapsed: Duration) -> String {
        (summary.map(short) ?? name) + " · " + elapsed.formatted(.time(pattern: .minuteSecond))
    }

    /// A summary short enough to sit beside the time, cut at a word.
    static func short(_ summary: String) -> String {
        guard summary.count > summaryLength else { return summary }
        let cut = summary.prefix(summaryLength - 1)
        var words = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        while let last = words.last, last.isWhitespace || last.isPunctuation { words.removeLast() }
        return String(words) + "…"
    }
}
