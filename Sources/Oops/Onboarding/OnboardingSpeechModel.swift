import Foundation
import OopsCore

/// The speech model first run downloads once Dictate is chosen: the one recommended for the language it infers.
/// The download starts unasked, says so once, and carries on behind every step and after onboarding closes.
@MainActor @Observable final class OnboardingSpeechModel {
    enum Phase: Equatable {
        case downloading(Double)
        case verifying
        case paused
        case failed(String)
        /// A model is there to dictate with: this download, one already installed, or OpenAI's with a key.
        case ready
    }

    private(set) var language: String
    private(set) var started = false
    private(set) var paused = false
    /// The download's one announcement: the pill opens wide with what it fetches, then folds to its progress.
    private(set) var announcing = false
    @ObservationIgnored private let providers: ProviderStore?
    @ObservationIgnored private let local: LocalModels
    /// A run that saves nothing downloads nothing: its progress is acted.
    private var acted: Phase?
    @ObservationIgnored private var acting: Task<Void, Never>?

    init(providers: ProviderStore?, local: LocalModels = .shared) {
        self.providers = providers; self.local = local
        language = SpeechLanguage.firstRun(preferred: Locale.preferredLanguages, keyboards: KeyboardInputSources.shared.enabled().map(\.languages))
        #if DEBUG
        if let phase = DebugFlags.onboardingSpeech { started = true; acted = Self.seeded(phase) }
        #endif
    }

    var model: SpeechModel {
        SpeechModelCatalog.model(id: SpeechModelCatalog.recommendedSelection(for: language).modelID) ?? SpeechModelCatalog.models[0]
    }
    /// "731 MB", "2.41 GB": whole megabytes, as the catalog's own figures read.
    var size: String {
        let megabytes = Double(model.artifact.byteCount) / 1_000_000
        return megabytes < 1000 ? "\(Int(megabytes.rounded())) MB" : "\((megabytes / 1000).formatted(.number.precision(.fractionLength(2)))) GB"
    }
    /// The Language menu: Hex's list, Auto first.
    var languages: [(value: String, label: String)] { SpeechLanguage.listed.map { ($0.code, $0.code == SpeechLanguage.auto ? "Automatic" : $0.name) } }

    var phase: Phase {
        if let acted { return acted }
        guard let providers else { return .paused }
        if providers.dictateOption(local) != nil { return .ready }
        switch local.state(model) {
        case .installed: return .ready
        case .downloading(let fraction): return .downloading(fraction)
        case .verifying: return .verifying
        case .failed(let message): return .failed(message)
        case .notInstalled: return .paused
        }
    }
    /// The download's share done, for the pill's ring and Try it's bar.
    var fraction: Double {
        switch phase {
        case .downloading(let fraction): fraction
        case .verifying, .ready: 1
        case .paused, .failed: 0
        }
    }

    /// Dictate was chosen: selects the model for dictation and fetches it, unless one can already be used.
    func start() {
        guard !started else { return }
        started = true
        announce()
        fetch()
    }

    private func fetch() {
        paused = false
        guard let providers else { return act() }
        Task {
            await local.refresh()
            guard providers.dictateOption(local) == nil else { return }
            providers.chooseDictateModel(.local(model.id))
            providers.chooseDictateLanguage(language)
            if !local.isInstalled(model.id) { local.download(model) }
        }
    }

    func pause() {
        paused = true
        if providers == nil { acting?.cancel(); acted = .paused } else { local.cancel(model) }
    }
    /// Resume and Retry: the store picks a partial file up where it stopped.
    func resume() { fetch() }

    /// Another language can mean another model: the one being fetched stops, its partial file kept.
    func choose(language code: String) {
        guard code != language else { return }
        let previous = model
        language = code
        guard started else { return }
        if previous.id != model.id, providers != nil, !local.isInstalled(previous.id) { local.cancel(previous) }
        if previous.id == model.id { providers?.chooseDictateLanguage(code) } else { fetch() }
    }

    /// An OpenAI key was set up instead: its live transcription is Dictate's model and nothing is downloaded.
    func useOpenAI(_ reference: VoiceModelReference) {
        pause()
        providers?.chooseDictateModel(reference)
    }

    private func announce() {
        announcing = true
        Task { try? await Task.sleep(for: .seconds(4.5)); announcing = false }
    }

    private func act() {
        acting?.cancel()
        var done = fraction
        acted = .downloading(done)
        acting = Task {
            while done < 1, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                done = min(1, done + 0.006)
                acted = .downloading(done)
            }
            if !Task.isCancelled { acted = .ready }
        }
    }

    #if DEBUG
    private static func seeded(_ name: String) -> Phase {
        switch name {
        case "failed": .failed("Couldn’t connect. Try again.")
        case "paused": .paused
        case "verifying": .verifying
        case "ready": .ready
        default: .downloading(Double(name) ?? 0.42)
        }
    }
    #endif
}
