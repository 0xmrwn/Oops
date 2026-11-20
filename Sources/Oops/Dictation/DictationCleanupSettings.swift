import Foundation
import Observation
import OopsCore

extension DictationCleanupMode {
    /// Where Settings keeps Clean up, by raw value.
    static let key = "DictationCleanUp"
    /// Clean up as saved, off until it's chosen.
    static var saved: DictationCleanupMode { UserDefaults.standard.string(forKey: key).flatMap(Self.init(rawValue:)) ?? .off }
    /// The Clean up choice's values, in its order.
    static let choices: [(value: DictationCleanupMode, label: String)] = [(.off, "Off"), (.basic, "Basic"), (.ai, "AI")]

    /// Set once Clean up is saved as a level.
    static let levelsKey = "DictationCleanUpLevels"

    /// Clean up as it was saved before the levels, once: Always cleaned with the model, so it is AI; Off and Button
    /// wrote the transcript after the small cleanups, so they are Basic when one is switched on and Off otherwise.
    /// Off is a level too, so a flag, not the value, tells that it's done.
    static func migrate(_ defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: levelsKey) else { return }
        defaults.set(true, forKey: levelsKey)
        let saved = defaults.string(forKey: key)
        if let saved, Self(rawValue: saved).map({ $0 != .off }) == true { return }
        let small = [SmallCleanups.fillersKey, SmallCleanups.formattingKey, SmallCleanups.symbolsKey].contains { defaults.bool(forKey: $0) }
        let level: Self = saved == "always" ? .ai : small ? .basic : .off
        if saved != nil || level != .off { defaults.set(level.rawValue, forKey: key) }
    }
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
