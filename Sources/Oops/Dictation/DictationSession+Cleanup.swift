import Foundation
import OopsCore

/// What a transcript goes through between the engine and the caret, in this order: the vocabulary (inside the engine,
/// or fuzzy replacement after it), the small cleanups unless Clean up is Off, then the cleanup model when it is AI or
/// the dictation came from "Clean up with AI". Below AI, the drop offers the model's cleanup once the text is in.
extension DictationSession {
    /// Where each step's settings come from; each is read when a recording starts.
    struct Cleanup {
        /// The vocabulary as the recording's model takes it; nil sends nothing.
        var vocabulary: @MainActor () -> VocabularyDelivery? = { nil }
        var small: @MainActor () -> SmallCleanups = { .off }
        /// The dictation's language for the filler words: the chosen one, or what Automatic means on the model.
        var language: @MainActor () -> String? = { nil }
        var mode: @MainActor () -> DictationCleanupMode = { .off }
        /// Whether a cleanup model is chosen, without building its backend (which may read the Keychain): what the
        /// drop's button needs to be offered.
        var available: @MainActor () -> Bool = { false }
        /// The cleanup model; throws when none is chosen. Built only when a cleanup runs.
        var backend: @MainActor () throws -> any CorrectionBackend = { throw CorrectionError.failure(.setup, "Choose a model for Clean up.") }
        var timeout = CleanupPrompt.timeout
        /// Replaces `inserted`, the text the last insert wrote, with `cleaned`, only while the field still reads it.
        var replace: @MainActor (_ inserted: String, _ cleaned: String) async -> InsertReplacement = { _, _ in .changed }
        /// Whether the field still reads `inserted`, which the last insert wrote, with the caret right after it.
        var intact: @MainActor (_ inserted: String) async -> Bool = { _ in false }
        /// The "Clean up with AI" shortcut's keys, for the drop's button; nil while it has none.
        var shortcutLabel: @MainActor () -> String? = { nil }

        static let none = Cleanup()
    }

    /// One recording's steps, as read at its start.
    struct CleanupPlan {
        var vocabulary: VocabularyDelivery?
        var small = SmallCleanups.off
        var language: String?
        var mode = DictationCleanupMode.off

        /// What the engine receives: the list for its own mechanism, never what fuzzy replacement or OpenAI takes.
        var engineVocabulary: VocabularyDelivery? {
            switch vocabulary {
            case .parakeetBias?, .prompt?: vocabulary
            default: nil
            }
        }
    }

    /// The steps for the recording starting now; `forced` (the "Clean up with AI" shortcut) has the model clean it
    /// whatever Clean up says, while the small cleanups still follow the level.
    func planCleanup(forced: Bool) -> CleanupPlan {
        let level = cleanup.mode()
        return CleanupPlan(vocabulary: cleanup.vocabulary(), small: level == .off ? .off : cleanup.small(),
                           language: cleanup.language(), mode: forced ? .ai : level)
    }

    /// `transcript` with the vocabulary's fuzzy replacement and the small cleanups, then, when this dictation is
    /// cleaned before it's written, the model's cleanup; the text before the model, and `failed`, when it fails.
    func polish(_ transcript: String) async -> (text: String, failed: Bool) {
        let prepared = DictationText.prepare(transcript, vocabulary: plan.vocabulary, cleanups: plan.small, language: plan.language)
        guard plan.mode == .ai else { return (prepared, false) }
        drop.show(.cleaningUp)
        guard let cleaned = await clean(prepared) else { return (prepared, true) }
        return (cleaned, false)
    }

    /// Whether the drop may offer the model's cleanup of a dictation just written: not one the model already
    /// cleaned, and only with a model chosen to do it.
    var offersCleanup: Bool { plan.mode != .ai && cleanup.available() }

    /// "Clean up with AI" pressed while no dictation is under way: the model cleans the last dictation's text, while
    /// the field still reads it with the caret after it, instead of a new dictation. False when it isn't intact;
    /// true, and the press is spent, when it is, even where Fix holds the drop and the cleanup can't start.
    func cleanLastWritten() async -> Bool {
        guard !holdsDrop, !activation.isRecording, let text = lastWritten, await cleanup.intact(text) else { return false }
        cleanUpWritten(text)
        return true
    }

    /// The model's cleanup of `text`, or nil when there's no model or it fails, takes too long or answers nothing.
    func clean(_ text: String) async -> String? {
        let began = ContinuousClock.now
        guard let backend = try? cleanup.backend() else {
            Self.log.notice("cleanup skipped=noModel")
            return nil
        }
        let cleaned = await CleanupPrompt.clean(text, with: backend, timeout: cleanup.timeout)
        Self.log.notice("cleanup cleaned=\(cleaned != nil, privacy: .public) ms=\(DebugLog.milliseconds(since: began), privacy: .public)")
        return cleaned
    }

    /// The drop's state once `text` is written below AI: it offers the model's cleanup, under the shortcut's name.
    func offer(_ text: String) {
        let label = ShortcutSettings.Action.dictateAndCleanUp.title + (cleanup.shortcutLabel().map { " · " + $0 } ?? "")
        drop.show(.written, action: DropAction(symbol: "wand.and.sparkles", label: label) { [weak self] in self?.cleanUpWritten(text) })
    }

    /// The drop's "Clean up with AI", or its shortcut: the model rewrites `text`, which the last dictation wrote, and the
    /// rewrite replaces it only while the field still reads what dictation wrote; otherwise nothing is replaced and the
    /// drop says so. Refused where Fix holds the drop, as a recording is.
    func cleanUpWritten(_ text: String) {
        guard !holdsDrop else { return }
        guard drop.claim(busy: { [weak self] in self?.holdsDrop == true }) else {
            status(CorrectionSession.dropTaken)
            return Self.log.notice("cleanup button refused=dropHeld")
        }
        holdsDrop = true
        turn += 1
        let mine = turn
        drop.show(.cleaningUp)
        Task { [weak self] in
            guard let self else { return }
            let cleaned = await clean(text)
            // A dictation started meanwhile owns the field, the kept transcript and the drop: this cleanup
            // touches none of them, even where the new dictation wrote the same words.
            guard turn == mine else { return Self.log.notice("cleanup button ending=superseded") }
            let ending: Ending
            if let cleaned {
                let outcome: InsertReplacement = sameText(cleaned, text) ? .replaced : await cleanup.replace(text, cleaned)
                guard turn == mine else { return Self.log.notice("cleanup button ending=superseded") }
                switch outcome {
                case .replaced: ending = .done; lastTranscript = cleaned
                case .changed: ending = .failed(.textChanged)
                case .failed: ending = .failed(.cannotWrite)
                }
            } else {
                ending = .failed(.cleanup)
            }
            Self.log.notice("cleanup button ending=\(String(describing: ending), privacy: .public)")
            conclude(ending)
        }
    }
}

/// What became of replacing a dictation's text with its cleanup.
enum InsertReplacement: Equatable, Sendable {
    case replaced
    /// The field no longer reads what dictation wrote: nothing replaced.
    case changed
    /// The field read the same but the replacement didn't go through.
    case failed
}
