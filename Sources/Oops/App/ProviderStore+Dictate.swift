import Foundation
import Observation
import OopsCore

/// Dictate's model and language, and what the slow capability steps learned, kept beside Fix's choice. Fix's
/// choice stays in `ProviderStore` under the key it has always used (`ModelFeature.fix.preferenceKey`).
@Observable @MainActor final class FeatureModels {
    fileprivate(set) var dictate = DictateSelection()
    fileprivate(set) var answers = CapabilityAnswers()
    fileprivate(set) var feed: ModelsDevFeed?
    /// Oops's own catalog (step 1): the speech models it manages on this Mac.
    @ObservationIgnored var catalog: CapabilityResolver.CatalogLookup = SpeechModelCatalog.capabilityLookup
    /// The one-time check (step 4); nil until the app can send a clip, so unknown models go to the user.
    @ObservationIgnored var probe: CapabilityProbe?
    @ObservationIgnored let client: ModelsDevClient
    @ObservationIgnored fileprivate var fetchedAt: Date?
    @ObservationIgnored fileprivate var probing: Set<String> = []
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored let preview: Bool

    static let answersKey = "modelCapabilityAnswers"
    static let modelsDevDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("oops/ModelsDev", isDirectory: true)

    init(defaults: UserDefaults, preview: Bool, client: ModelsDevClient = ModelsDevClient(directory: modelsDevDirectory)) {
        self.defaults = defaults; self.preview = preview; self.client = client
        guard !preview else { return }
        let decoder = JSONDecoder()
        if let data = defaults.data(forKey: ModelFeature.dictate.preferenceKey),
           let saved = try? decoder.decode(DictateSelection.self, from: data) { dictate = saved }
        if let data = defaults.data(forKey: Self.answersKey), let saved = try? decoder.decode(CapabilityAnswers.self, from: data) { answers = saved }
        feed = client.cached()
    }

    fileprivate func save() {
        guard !preview else { return }
        let encoder = JSONEncoder()
        defaults.set(try? encoder.encode(dictate), forKey: ModelFeature.dictate.preferenceKey)
        defaults.set(try? encoder.encode(answers), forKey: Self.answersKey)
    }
}

extension ProviderStore {
    var dictateSelection: DictateSelection { features.dictate }

    /// Switches Dictate's model; the language follows `DictateSelection.switchModel`'s rule.
    func selectDictate(_ model: VoiceModelReference?, languages: any SpeechLanguageSupport?) {
        features.dictate.switchModel(to: model, languages: languages)
        features.save()
    }

    /// nil is Automatic.
    func selectDictate(language: String?) {
        features.dictate.language = language
        features.save()
    }

    // MARK: Capability answers

    /// Stores the user's answer (step 5) for a model nothing else could identify.
    func answerCapabilities(_ choice: ModelSelection.Choice, voice: Bool) {
        features.answers.user[CapabilityAnswers.key(choice)] = voice
        features.save()
    }

    /// Runs the one-time check (step 4) for a model that needs it, once ever: its verdict is kept, and a check
    /// already running or done is not repeated.
    func probeCapabilities(_ choice: ModelSelection.Choice) async {
        let key = CapabilityAnswers.key(choice)
        guard let probe = features.probe, let provider = provider(choice.providerID), features.answers.probes[key] == nil,
              !features.probing.contains(key) else { return }
        features.probing.insert(key)
        defer { features.probing.remove(key) }
        let outcome = await probe(provider, choice.modelID)
        features.answers.probes[key] = outcome
        features.save()
    }

    /// Revalidates models.dev's feed, at most once an hour; offline, the copy on disk stays in use. Only Dictate
    /// reads it, so a build without dictation asks nothing.
    func refreshModelsDev() {
        guard !features.preview, DebugFlags.dictation else { return }
        if let fetched = features.fetchedAt, Date().timeIntervalSince(fetched) < 3600 { return }
        features.fetchedAt = Date()
        let client = features.client
        Task {
            let feed = await client.load()
            if let feed, feed != features.feed { features.feed = feed }
        }
    }
}
