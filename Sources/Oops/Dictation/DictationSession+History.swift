import Foundation
import OopsCore

/// Paste last dictation and history entries, written again at the caret. History is the one place dictated words
/// outlive the run: the session hands it each finished dictation and reads Paste last's text from it.
extension DictationSession {
    /// The history the session records into (`DictationHistoryModel` in the app); `.none` keeps nothing past the run.
    struct History {
        /// A finished dictation's text and the language hint it ran with (nil: automatic).
        var record: @MainActor (_ text: String, _ language: String?) -> Void = { _, _ in }
        /// "Clean up with AI" replaced the text the last recorded dictation wrote.
        var replaceLast: @MainActor (String) -> Void = { _ in }
        /// What Paste last dictation writes, given the transcript held in memory.
        var last: @MainActor (_ inMemory: String?) -> String? = { $0 }

        static let none = History()
    }

    /// Writes the last dictation again at the caret, once no dictation is under way.
    func pasteLast() { events.yield(.pasteLast) }

    /// Writes a history entry's `text` at the caret, as Paste last does. It records nothing.
    func paste(_ text: String) { events.yield(.paste(text)) }

    /// Whether Paste last dictation has anything to write.
    var canPasteLast: Bool { history.last(lastTranscript) != nil }

    /// Paste last dictation or a history entry, as Hex's recovery: never past a dictation under way, and with nothing
    /// to write, nothing. Where no field has focus, the drop offers to copy `text`. `what` names it in the log.
    func writeAgain(_ text: String?, what: String) async {
        guard !holdsDrop, !activation.isRecording, let text else {
            return Self.log.notice("paste \(what, privacy: .public) refused busy=\(self.holdsDrop, privacy: .public) kept=\(text != nil, privacy: .public)")
        }
        // Held as a dictation holds it, so Fix can't start on the draft this is about to change, nor this
        // write into one Fix is working on.
        guard drop.claim(busy: { [weak self] in self?.holdsDrop == true }) else {
            status(CorrectionSession.dropTaken)
            return Self.log.notice("paste \(what, privacy: .public) refused=dropHeld")
        }
        holdsDrop = true
        let ending = Self.ending(await insert(text))
        // Written: nothing to show. Otherwise the drop says why, as after a dictation.
        if ending == .done { holdsDrop = false } else { conclude(ending, copying: text) }
    }
}
