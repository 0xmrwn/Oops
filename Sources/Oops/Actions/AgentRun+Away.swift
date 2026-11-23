import AppKit
import OopsCore

/// An agent run while the person is elsewhere: its drop parked at the screen's edge, the result waiting there when it
/// ends, and waiting at the caret of its own field once they come back, where Return puts it in and Escape parks it
/// again. The result is never shown at the caret of another field.
extension AgentRun {
    /// The ready result in the pill: open, with its glow, the first time it shows; with the sound the first time it is
    /// announced. While another feature holds the drop the sound alone says it's ready, and the pill follows once it's free.
    func announceReady() {
        guard flow.phase == .ready, flow.place == .parked, !flow.fullScreen else { return }
        if drop.showReady(name, open: !unfolded, cue: !announced) { unfolded = true } else if !announced { cue(.success) }
        announced = true
    }

    /// Ready while the pill can't show: the sound, once.
    func chime() {
        if !announced { cue(.success) }
        announced = true
    }

    /// The person is back in the run's field with its result ready: the drop flies to the caret.
    func showReadyHere() {
        guard let snapshot else { return }
        drop.showReady(name, element: snapshot.element, fallback: snapshot.geometry) { [weak self] in self?.flow.readyHere == true }
    }

    /// In the pill when the run was parked, at the run's caret when the person was there.
    func showFailure(parked: Bool) {
        guard let failure else { return }
        if !drop.showFailure(failure, geometry: parked ? nil : snapshot?.geometry) { cue(.failure) }
    }

    /// The draft changed under the ready drop: the answer is offered to copy there, as a refused write's is.
    func offerCopy() {
        copyable = held; held = nil
        let words = Self.held(ActionDraftChanged())
        drop.showHeld(words.reason, label: words.label, geometry: nil)
        resolve(.held)
    }

    /// Escape: the ready drop at the caret goes back to the pill; otherwise the running drop in front is cancelled.
    func escaped() {
        if flow.readyHere { handle(.escape) } else { cancel() }
    }

    /// Return, with the ready drop at the caret of its field: put in, if the draft still reads as it was read. A draft
    /// changed meanwhile keeps the Return it was typed for, and the answer is offered to copy.
    func confirmed() {
        guard flow.readyHere, let snapshot else { return passReturn() }
        let unchanged = draftUnchanged
        Task {
            let same = await Task.detached { unchanged(snapshot) }.value
            guard flow.readyHere else { return passReturn() }
            if same { return handle(.confirm) }
            // The hotkey goes with the ready drop, so the Return sent on reaches the field.
            handle(.edited)
            passReturn()
        }
    }

    /// Return, pressed again for the app in front once the hotkey that took it has gone.
    static func pressReturn() {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] { CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: down)?.post(tap: .cghidEventTap) }
    }
}
