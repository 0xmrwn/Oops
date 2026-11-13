import Foundation
import Observation
import OopsCore

extension DictationCleanupMode {
    /// Where Settings keeps Clean up, by raw value.
    static let key = "DictationCleanUp"
    /// Clean up as saved, off until it's chosen.
    static var saved: DictationCleanupMode { UserDefaults.standard.string(forKey: key).flatMap(Self.init(rawValue:)) ?? .off }
    /// The Clean up choice's values, in its order.
    static let choices: [(value: DictationCleanupMode, label: String)] = [(.off, "Off"), (.button, "Button"), (.always, "Always")]
}

extension SmallCleanups {
    /// Where Settings keeps each switch; all off until switched on.
    static let fillersKey = "DictationRemoveFillers", formattingKey = "DictationSpokenFormatting", symbolsKey = "DictationSpokenSymbols"

    static var saved: SmallCleanups {
        let defaults = UserDefaults.standard
        return SmallCleanups(fillers: defaults.bool(forKey: fillersKey), formatting: defaults.bool(forKey: formattingKey),
                             symbols: defaults.bool(forKey: symbolsKey))
    }
}

/// The vocabulary: the user's terms, in the order they matter, each with its "sounds like" spellings. Kept as JSON in
/// the defaults, and read by each dictation as it starts.
@MainActor @Observable final class VocabularyStore {
    static let shared = VocabularyStore()
    static let key = "DictationVocabulary"

    private(set) var entries: [VocabularyEntry]
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        entries = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([VocabularyEntry].self, from: $0) } ?? []
    }

    /// Adds `term`, or merges `soundsLike` into it when it's there already; throws past the limits.
    func add(_ term: String, soundsLike: String) throws {
        guard try Vocabulary.add(&entries, term: term, soundsLike: Vocabulary.parseSoundsLike(soundsLike)) else { return }
        save()
    }

    func remove(_ term: String) {
        guard Vocabulary.remove(&entries, term: term) else { return }
        save()
    }

    private func save() { defaults.set(try? JSONEncoder().encode(entries), forKey: Self.key) }
}
