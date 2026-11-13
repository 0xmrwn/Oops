import Foundation

// What each engine mechanism receives from the list, ported from Hex (github.com/anomalyco/hex,
// `src/dictation/vocabulary.rs` at 1b82cc0; MIT, Copyright (c) 2026 Christopher Langton): `bias_for`,
// `prompt_for`, `prompt_chars`, `terms_read` and `VocabularyBoost`.

/// How readily transcription swaps heard words for a vocabulary term that sounds like them.
public enum VocabularyBoost: String, Codable, Sendable, CaseIterable {
    /// Transcripts are left as the model heard them.
    case off
    case light
    case normal
    case strong

    /// How much less likely than the heard words, in nats per term piece, a term may score and still replace them.
    public var nats: Float {
        switch self {
        case .off: 0
        case .light: 2
        case .normal: 2.5
        case .strong: 4
        }
    }
}

/// What a Parakeet run biases its transcript with: the terms, and the declared "sounds like" spellings by the index
/// of the term they stand for.
public struct VocabularyBias: Sendable, Equatable {
    public struct SoundsLike: Sendable, Equatable {
        public var termIndex: Int
        public var spelling: String
    }

    /// Most terms one transcription is biased toward, first in list order: the engine's own cap
    /// (`k_vocab_max_terms` in transcribe.cpp), which keeps the biasing a bounded cost per decode.
    public static let maxTerms = 64

    public var terms: [String]
    public var soundsLike: [SoundsLike]
    public var boost: Float

    /// The first terms in list order, with their spellings; nil while the list is empty or the boost is off.
    public static func make(_ entries: [VocabularyEntry], boost: VocabularyBoost = .normal) -> VocabularyBias? {
        let entries = entries.prefix(maxTerms)
        if entries.isEmpty || boost == .off { return nil }
        return VocabularyBias(
            terms: entries.map(\.term),
            soundsLike: entries.enumerated().flatMap { index, entry in
                entry.soundsLike.map { SoundsLike(termIndex: index, spelling: $0) }
            },
            boost: boost.nats
        )
    }
}

public enum VocabularyPrompt {
    /// How much of the vocabulary a context prompt carries, in characters, for a model of this architecture; nil
    /// for one without a prompt. Whisper's prompt slot holds 223 tokens and its engine trims an overlong one from
    /// the front, dropping the first (most important) terms, so the list stays well inside it. Qwen3-ASR's system
    /// message has far more room; the bound keeps a long list from crowding out the audio or being echoed.
    public static func maxCharacters(for architecture: SpeechModelArchitecture) -> Int? {
        switch architecture {
        case .whisper: 500
        case .qwen3ASR: 1_000
        default: nil
        }
    }

    /// The context prompt a Whisper or Qwen3-ASR run reads: the first terms in list order, comma-separated so an
    /// echo filter can recognise the list, and as many as fit `maxCharacters`. The bias's term cap is Parakeet's
    /// and does not apply here. Nil while nothing fits.
    public static func make(_ entries: [VocabularyEntry], maxCharacters: Int) -> String? {
        let terms = entries.prefix(termsFitting(entries, maxCharacters))
        return terms.isEmpty ? nil : terms.map(\.term).joined(separator: ", ")
    }

    /// How many of the first terms fit `maxCharacters` joined by ", ".
    static func termsFitting(_ entries: [VocabularyEntry], _ maxCharacters: Int) -> Int {
        var characters = 0
        for (index, entry) in entries.enumerated() {
            characters += (index == 0 ? 0 : 2) + entry.term.unicodeScalars.count
            if characters > maxCharacters { return index }
        }
        return entries.count
    }

    /// How many of `entries`, first in list order, a model of this architecture reads: Parakeet's bias cap, or the
    /// terms that fit the prompt.
    public static func termsRead(_ entries: [VocabularyEntry], architecture: SpeechModelArchitecture) -> Int {
        if architecture == .parakeet { return min(entries.count, VocabularyBias.maxTerms) }
        return maxCharacters(for: architecture).map { termsFitting(entries, $0) } ?? 0
    }
}
