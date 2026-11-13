import Foundation
import Observation
import OopsCore

/// Keyboard model switching, live: hears the selected input source and, `KeyboardModelSwitcher.debounce` after the
/// last change, hands Dictate the model and language mapped to it. The rules are the switcher's; this keeps its
/// mappings, feeds it and keeps one timer. It listens only once `start` says dictation is on and a mapping exists.
@Observable @MainActor final class KeyboardModelDriver {
    /// Where the mappings are kept, as `KeyboardModelSwitchSettings` in JSON.
    static let key = "DictationKeyboardModels"

    static let shared = KeyboardModelDriver(defaults: .standard, sources: { KeyboardInputSources.shared.changes() })

    private(set) var settings: KeyboardModelSwitchSettings
    /// Whether a mapped model is there to switch to; one that isn't is left alone. Nothing is downloaded.
    @ObservationIgnored var isInstalled: @MainActor (String) -> Bool = { _ in false }
    @ObservationIgnored var apply: @MainActor (KeyboardModelChoice) -> Void = { _ in }
    @ObservationIgnored private var switcher: KeyboardModelSwitcher
    @ObservationIgnored private var started = false
    @ObservationIgnored private var listening: Task<Void, Never>?
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let sources: @MainActor () -> AsyncStream<String?>
    @ObservationIgnored private let now: @MainActor () -> ContinuousClock.Instant
    @ObservationIgnored private let sleep: @MainActor (Duration) async -> Void

    /// `defaults` nil keeps the mappings in memory only (previews, tests).
    init(defaults: UserDefaults?, sources: @escaping @MainActor () -> AsyncStream<String?>,
         now: @escaping @MainActor () -> ContinuousClock.Instant = { .now },
         sleep: @escaping @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {
        self.defaults = defaults; self.sources = sources; self.now = now; self.sleep = sleep
        let saved = defaults?.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(KeyboardModelSwitchSettings.self, from: $0) }
        let settings = saved ?? KeyboardModelSwitchSettings()
        self.settings = settings
        switcher = KeyboardModelSwitcher(settings: settings, current: nil)
    }

    var isListening: Bool { listening != nil }

    /// Dictation is on: listen whenever a mapping exists.
    func start() {
        started = true
        updateListening()
    }

    func mapping(_ source: String) -> KeyboardModelChoice? { settings.mappings[source] }

    /// Maps a source to a model and language, or nil for Don't switch.
    func setMapping(_ choice: KeyboardModelChoice?, for source: String) {
        settings.mappings[source] = choice
        settings.enabled = !settings.mappings.isEmpty
        defaults?.set(try? JSONEncoder().encode(settings), forKey: Self.key)
        if switcher.configure(settings, now: now()) { schedule() }
        updateListening()
    }

    /// The person picked a model: it stands until the source changes again.
    func manualChoice() {
        switcher.manualChoice()
        timer?.cancel()
    }

    private func updateListening() {
        guard started, settings.enabled else {
            listening?.cancel(); listening = nil; timer?.cancel()
            return
        }
        guard listening == nil else { return }
        let stream = sources()
        listening = Task { [weak self] in
            for await source in stream {
                guard let self, !Task.isCancelled else { return }
                if switcher.sourceChanged(source, now: now()) { schedule() }
            }
        }
    }

    private func schedule() {
        timer?.cancel()
        timer = Task { [weak self] in
            guard let self else { return }
            await sleep(KeyboardModelSwitcher.debounce)
            guard !Task.isCancelled, let choice = switcher.takeDue(now: now()), isInstalled(choice.modelID) else { return }
            apply(choice)
        }
    }
}
