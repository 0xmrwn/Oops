import Foundation

/// What a model can do, and which step of `CapabilityResolver` found out.
public struct ModelCapabilities: Codable, Equatable, Sendable {
    /// The resolution steps, in the order they are tried.
    public enum Source: String, Codable, Sendable { case catalog, provider, name, probe, user }

    /// Can correct and transform text (Fix, Actions).
    public var text: Bool
    /// Speech to text (Dictate).
    public var voice: Bool
    /// Returns words while audio still arrives (live words).
    public var streaming: Bool
    /// BCP-47 codes it transcribes; nil when unknown, which Dictate treats as any language.
    public var languages: [String]?
    public var source: Source

    public init(text: Bool, voice: Bool, streaming: Bool = false, languages: [String]? = nil, source: Source) {
        self.text = text; self.voice = voice; self.streaming = streaming; self.languages = languages; self.source = source
    }

    /// A model that only transcribes; nothing found so far has corrected text as well.
    static func speechToText(streaming: Bool, source: Source) -> ModelCapabilities {
        ModelCapabilities(text: false, voice: true, streaming: streaming, source: source)
    }
}

/// The one-time check's verdict, kept so it never runs twice for a model. `inconclusive` is kept too: a
/// check that couldn't tell once would not tell the next time either, so the user is asked instead.
public enum ProbeOutcome: String, Codable, Sendable { case voice, notVoice, inconclusive }

/// The one-time check: sends a short clip to the model and says whether text came back. The app supplies it.
public typealias CapabilityProbe = @Sendable (_ provider: Provider, _ modelID: String) async -> ProbeOutcome

/// What the slow steps learned, kept across launches: probe verdicts and the user's answers, per model.
public struct CapabilityAnswers: Codable, Equatable, Sendable {
    public var probes: [String: ProbeOutcome]
    /// true: the user said the model transcribes speech.
    public var user: [String: Bool]

    public init(probes: [String: ProbeOutcome] = [:], user: [String: Bool] = [:]) { self.probes = probes; self.user = user }

    public static func key(_ choice: ModelSelection.Choice) -> String { choice.key }
}

public enum CapabilityResolution: Equatable, Sendable {
    case resolved(ModelCapabilities)
    /// Steps 1–3 couldn't tell; the one-time check should run, then resolve again.
    case needsProbe
    /// Nothing could tell; only the user can.
    case needsUserAnswer

    public var capabilities: ModelCapabilities? { if case .resolved(let value) = self { value } else { nil } }
}

/// Decides what a model can do, trying the cheapest and surest knowledge first: (1) Oops's own catalog,
/// (2) what the provider reports, models.dev included, (3) the model's name, (4) a one-time check with a
/// short clip, (5) the user. Pure: the slow steps' results come in as stored values.
public struct CapabilityResolver: Sendable {
    /// Oops's own knowledge of a model; `kind` nil is a model Oops manages on this Mac.
    public typealias CatalogLookup = @Sendable (_ kind: Provider.Kind?, _ modelID: String) -> ModelCapabilities?

    public let catalog: CatalogLookup
    public let feed: ModelsDevFeed?

    public init(catalog: @escaping CatalogLookup = { _, _ in nil }, feed: ModelsDevFeed? = nil) {
        self.catalog = catalog; self.feed = feed
    }

    /// `reported` is what the provider's own API said (e.g. Ollama's `/api/show`); `probe` and `answer` are
    /// stored results of steps 4 and 5. `canProbe` is false while the app has no check to run.
    public func resolve(modelID: String, kind: Provider.Kind?, reported: ModelCapabilities? = nil,
                        probe: ProbeOutcome? = nil, answer: Bool? = nil, canProbe: Bool) -> CapabilityResolution {
        switch kind {
        case .chatGPT?, .claudeCode?:
            // Subscriptions never transcribe: OpenAI keeps audio out of subscription sharing; Claude Code is text.
            return .resolved(ModelCapabilities(text: true, voice: false, source: .catalog))
        default: break
        }
        if var known = catalog(kind, modelID) { known.source = .catalog; return .resolved(known) }
        if var reported { reported.source = .provider; return .resolved(reported) }
        if let listed = feed?.model(provider: kind.flatMap(ModelsDevFeed.providerID), id: modelID) {
            return .resolved(listed.capabilities(streaming: ModelName.streams(modelID)))
        }
        if let named = ModelName.capabilities(modelID) { return .resolved(named) }
        switch probe {
        case .voice?: return .resolved(.speechToText(streaming: false, source: .probe))
        case .notVoice?: return .resolved(ModelCapabilities(text: true, voice: false, source: .probe))
        case .inconclusive?, nil: break
        }
        // An answer the user already gave stands: no check is run to second-guess it.
        guard let answer else { return probe == nil && canProbe ? .needsProbe : .needsUserAnswer }
        return .resolved(answer ? .speechToText(streaming: false, source: .user) : ModelCapabilities(text: true, voice: false, source: .user))
    }
}

/// Step 3: what a model's id says. Only whole words count, so `gpt-4o-mini-tts` (text to speech) and audio-in
/// chat models such as `gpt-audio` are never taken for speech to text. Voxtral is left to the steps around it:
/// Mistral names a transcription model and an audio-in chat model with it alike.
public enum ModelName {
    /// Words only transcription models carry.
    static let speechToText: Set = ["whisper", "transcribe", "transcription", "transcriber", "asr", "stt", "parakeet"]
    /// Words for models that make audio or vectors rather than text: neither Fix nor Dictate can use them.
    static let neither: Set = ["tts", "embed", "embedding", "embeddings"]
    /// Chat models that hear audio. They answer, not transcribe, so Dictate doesn't offer them.
    static let audioChat: Set = ["audio", "realtime"]
    static let live: Set = ["live", "realtime", "streaming", "stream"]

    /// Lowercased words of an id: `openai/whisper-large-v3` → openai, whisper, large, v3.
    static func words(_ id: String) -> [String] {
        id.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    public static func capabilities(_ id: String) -> ModelCapabilities? {
        let words = words(id)
        if words.contains(where: { word in speechToText.contains(word) || word.hasPrefix("whisper") }) {
            return .speechToText(streaming: streams(id), source: .name)
        }
        if words.contains(where: neither.contains) { return ModelCapabilities(text: false, voice: false, source: .name) }
        if words.contains(where: audioChat.contains) { return ModelCapabilities(text: true, voice: false, source: .name) }
        return nil
    }

    /// Live transcription models say so in their id (`gpt-live-transcribe`, `mai-transcribe-2-streaming`).
    public static func streams(_ id: String) -> Bool { words(id).contains(where: live.contains) }
}
