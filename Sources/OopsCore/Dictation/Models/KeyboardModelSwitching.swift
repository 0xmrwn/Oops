import Foundation

// A port of Hex's keyboard model switching at v3.4.0 (MIT, github.com/anomalyco/hex): the policy of
// `src/transcription/keyboard_model_switching.rs` and the two settings types of `src/app_settings.rs` it reads.
// See THIRD_PARTY_NOTICES.md.

/// What one keyboard input source selects: a model and a language it supports.
public struct KeyboardModelChoice: Sendable, Equatable, Hashable, Codable {
    public var modelID: String
    public var language: String

    public init(modelID: String, language: String) {
        self.modelID = modelID
        self.language = language
    }

    /// Whether the catalog still offers this model with this language.
    public func validate() throws(SpeechModelSelectionError) {
        try SpeechModelCatalog.validate(SpeechModelSelection(modelID: modelID, language: language))
    }
}

/// Keyboard model switching as Dictate saves it: off, with no mappings, by default. Mappings are keyed by the
/// native input-source id (`com.apple.keylayout.Russian`).
public struct KeyboardModelSwitchSettings: Sendable, Equatable, Codable {
    public var enabled: Bool
    public var mappings: [String: KeyboardModelChoice]

    public init(enabled: Bool = false, mappings: [String: KeyboardModelChoice] = [:]) {
        self.enabled = enabled
        self.mappings = mappings
    }
}

/// One enabled keyboard input source, as Settings lists it.
public struct KeyboardInputSource: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    /// The source's languages, most specific first (`ru`, `zh-Hans`).
    public let languages: [String]

    public var primaryLanguage: String? { languages.first }

    public init(id: String, name: String, languages: [String]) {
        self.id = id
        self.name = name
        self.languages = languages
    }

    /// The language a new mapping to `model` starts with: the first of this source's languages the model
    /// supports, else `fallback`.
    public func language(for model: SpeechModel, fallback: String) -> String {
        languages
            .map { $0.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? $0 }
            .first { model.supports(language: $0) } ?? fallback
    }
}

/// Input-source changes are model-picker choices, not recording-time routing. This holds no models or workers: it
/// only admits the latest choice, after the debounce. Time comes in as an argument so tests need no timers.
public struct KeyboardModelSwitcher: Sendable {
    public static let debounce: Duration = .milliseconds(300)

    private var settings: KeyboardModelSwitchSettings
    /// The observed source; unknown while switching is off, so turning it on waits for the observer's first
    /// report instead of a stale source.
    private var current: String?
    private var due: ContinuousClock.Instant?

    public init(settings: KeyboardModelSwitchSettings, current: String?) {
        self.current = settings.enabled ? current : nil
        self.settings = settings
    }

    /// Returns true on a real change, so the owner can cancel obsolete work.
    public mutating func sourceChanged(_ source: String?, now: ContinuousClock.Instant) -> Bool {
        guard settings.enabled, current != source else { return false }
        current = source
        due = mapped == nil ? nil : now + Self.debounce
        return true
    }

    private var mapped: KeyboardModelChoice? {
        guard settings.enabled, let current else { return nil }
        return settings.mappings[current]
    }

    /// The choice to apply once its debounce has elapsed, at most once.
    public mutating func takeDue(now: ContinuousClock.Instant) -> KeyboardModelChoice? {
        guard let due, now >= due else { return nil }
        self.due = nil
        return mapped
    }

    /// A manual model choice supersedes the pending switch.
    public mutating func manualChoice() {
        due = nil
    }

    /// Only enabling, disabling, or editing the active mapping affects work. Returns true when the owner must
    /// supersede an automatic preparation.
    public mutating func configure(_ settings: KeyboardModelSwitchSettings, now: ContinuousClock.Instant) -> Bool {
        let before = (enabled: self.settings.enabled, choice: mapped)
        self.settings = settings
        if !settings.enabled { current = nil }
        guard before.enabled != settings.enabled || before.choice != mapped else { return false }
        due = mapped == nil ? nil : now
        return true
    }
}
