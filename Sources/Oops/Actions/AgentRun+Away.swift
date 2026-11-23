import AppKit
import os
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

    /// The draft changed under the ready drop: the answer is offered to copy where the drop is, as a refused write's
    /// is. False while another feature holds the drop: the result stays ready, and the offer follows once it's free.
    func offerCopy() -> Bool {
        guard let held else { return false }
        let words = Self.held(ActionDraftChanged()), parked = flow.place == .parked
        let geometry = parked || drop.readyAtCaret ? nil : snapshot?.geometry
        guard drop.showHeld(words.reason, label: words.label, geometry: geometry, park: parked) else { return false }
        copyable = held; self.held = nil
        resolve(.held)
        return true
    }

    /// How long a Return or Escape waits for the live checks before it goes to the app instead.
    static let keyCheck: DispatchTimeInterval = .milliseconds(120)

    /// Whether a Return or Escape press is the ready drop's (`AgentReadyKey.takes`): its field is asked, as the key
    /// arrives, whether it has focus and still holds the draft as read. A click into another field just before the
    /// press, or a word typed, leaves the key to the app.
    func takes(_ key: AgentReadyKey) -> Bool {
        let inFront = drop.readyAtCaret, atCaret = flow.readyHere
        guard inFront, atCaret, let snapshot else { return false }
        let holds = holdsFocus, unchanged = draftUnchanged
        let live = Self.bounded(Self.keyCheck) { () -> (Bool, Bool) in
            let focused = holds(snapshot)
            return (focused, focused && unchanged(snapshot))
        }
        return AgentReadyKey.takes(inFront: inFront, atCaret: atCaret, focused: live?.0, unchanged: live?.1)
    }

    /// A Return or Escape the ready drop took.
    func pressed(_ key: AgentReadyKey) {
        handle(key == .confirm ? .confirm : .escape)
    }

    /// `work`'s answer, or nil when it takes longer than `deadline`: the key it decides can't wait for it.
    static func bounded<T: Sendable>(_ deadline: DispatchTimeInterval, _ work: @escaping @Sendable () -> T) -> T? {
        let answer = OSAllocatedUnfairLock<T?>(initialState: nil), done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInteractive).async {
            let value = work()
            answer.withLock { $0 = value }
            done.signal()
        }
        guard done.wait(timeout: .now() + deadline) == .success else { return nil }
        return answer.withLock { $0 }
    }
}
