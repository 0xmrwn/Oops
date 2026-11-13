import Foundation
import OopsCore

/// What a transcript goes through between the engine and the caret, in this order: the vocabulary (inside the engine,
/// or fuzzy replacement after it), the small cleanups, then the cleanup model when Clean up is Always or the dictation
/// came from "Dictate and clean up". With Clean up on Button, the drop offers the model's cleanup once the text is in.
extension DictationSession {
    /// Where each step's settings come from; each is read when a recording starts.
    struct Cleanup {
        /// The vocabulary as the recording's model takes it; nil sends nothing.
        var vocabulary: @MainActor () -> VocabularyDelivery? = { nil }
        var small: @MainActor () -> SmallCleanups = { .off }
        /// The dictation's language for the filler words: the chosen one, or what Automatic means on the model.
        var language: @MainActor () -> String? = { nil }
        var mode: @MainActor () -> DictationCleanupMode = { .off }
        /// The cleanup model; throws when none is chosen.
        var backend: @MainActor () throws -> any CorrectionBackend = { throw CorrectionError.failure(.setup, "Choose a model for Clean up.") }
        var timeout = CleanupPrompt.timeout
        /// Replaces `inserted`, the text the last insert wrote, with `cleaned`, only while the field still reads it.
        var replace: @MainActor (_ inserted: String, _ cleaned: String) async -> InsertReplacement = { _, _ in .changed }

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

    /// The steps for the recording starting now; `forced` (the "Dictate and clean up" shortcut) cleans it whatever
    /// Clean up says.
    func planCleanup(forced: Bool) -> CleanupPlan {
        CleanupPlan(vocabulary: cleanup.vocabulary(), small: cleanup.small(), language: cleanup.language(),
                    mode: forced ? .always : cleanup.mode())
    }

    /// `transcript` with the vocabulary's fuzzy replacement and the small cleanups, then, when this dictation is
    /// cleaned before it's written, the model's cleanup; the text as heard when the model fails.
    func polish(_ transcript: String) async -> String {
        let prepared = DictationText.prepare(transcript, vocabulary: plan.vocabulary, cleanups: plan.small, language: plan.language)
        guard plan.mode == .always else { return prepared }
        drop.show(.cleaningUp)
        return await clean(prepared) ?? prepared
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

    /// The drop's state once `text` is written: with Clean up on Button, it offers to clean it up.
    func offer(_ text: String) {
        drop.show(.written, action: DropAction(symbol: "wand.and.sparkles", label: "Clean up") { [weak self] in self?.cleanUpWritten(text) })
    }

    /// The drop's "Clean up": the model rewrites `text`, which the last dictation wrote, and the rewrite replaces it
    /// only while the field still reads what dictation wrote; otherwise nothing is replaced and the drop says so.
    func cleanUpWritten(_ text: String) {
        guard !holdsDrop, drop.claim(busy: { [weak self] in self?.holdsDrop == true }) else { return }
        holdsDrop = true
        turn += 1
        let mine = turn
        drop.show(.cleaningUp)
        Task { [weak self] in
            guard let self else { return }
            let ending: Ending
            if let cleaned = await clean(text) {
                switch sameText(cleaned, text) ? .replaced : await cleanup.replace(text, cleaned) {
                case .replaced: ending = .done; lastTranscript = cleaned
                case .changed: ending = .failed(.textChanged)
                case .failed: ending = .failed(.cannotWrite)
                }
            } else {
                ending = .failed(.cleanup)
            }
            Self.log.notice("cleanup button ending=\(String(describing: ending), privacy: .public)")
            // A dictation started meanwhile has the drop now.
            guard turn == mine else { return }
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
