import Foundation

/// models.dev's transcription feed (`api.json?type=transcription`): providers by id, each with its models
/// by id. Only the fields Oops reads are decoded, and an entry that doesn't decode is skipped, so a feed that
/// grows or changes shape loses at most that entry.
public struct ModelsDevFeed: Decodable, Equatable, Sendable {
    public struct Model: Decodable, Equatable, Sendable {
        public struct Modalities: Decodable, Equatable, Sendable {
            public let input: [String]?, output: [String]?
        }
        public let id: String
        public let name: String?
        /// Sparse: `transcription`, `realtime`, `speech`, `embedding`…; absent for most chat models.
        public let type: String?
        /// The model's id at its maker (`openai/whisper-1`), the same across the providers that serve it.
        public let canonicalID: String?
        public let modalities: Modalities?

        enum CodingKeys: String, CodingKey { case id, name, type, modalities, canonicalID = "canonical_model_id" }

        /// Transcription models only transcribe; any other typed model (speech, embedding…) makes no text;
        /// an untyped one is a chat model when it reads and writes text.
        func capabilities(streaming: Bool) -> ModelCapabilities {
            if type == "transcription" { return .speechToText(streaming: streaming, source: .provider) }
            let text = type == nil && modalities?.input?.contains("text") == true
                && modalities?.output?.contains("text") == true
            return ModelCapabilities(text: text, voice: false, source: .provider)
        }
    }

    public struct Provider: Decodable, Equatable, Sendable {
        public let id: String
        public let models: [String: Model]

        enum CodingKeys: String, CodingKey { case id, models }
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            models = try container.decodeIfPresent([String: Skippable<Model>].self, forKey: .models)?.compactMapValues(\.value) ?? [:]
        }
    }

    public let providers: [String: Provider]

    public init(from decoder: any Decoder) throws {
        providers = try decoder.singleValueContainer().decode([String: Skippable<Provider>].self).compactMapValues(\.value)
    }

    public static func decode(_ data: Data) throws -> ModelsDevFeed { try JSONDecoder().decode(ModelsDevFeed.self, from: data) }

    /// The provider's own entry first, then any entry whose canonical id is the model: models.dev lists
    /// OpenAI's and Google's transcription models only under other providers, by canonical id. `provider` nil
    /// (an endpoint with no preset) matches by canonical id alone.
    public func model(provider: String?, id: String) -> Model? {
        if let provider, let own = providers[provider]?.models[id] { return own }
        let wanted = Set([id] + (provider.map { ["\($0)/\(id)"] } ?? []))
        // Sorted, so the same feed always answers with the same entry.
        for key in providers.keys.sorted() {
            if let match = providers[key]?.models.values.sorted(by: { $0.id < $1.id }).first(where: { $0.canonicalID.map(wanted.contains) ?? false }) {
                return match
            }
        }
        return nil
    }

    /// models.dev's id for an API provider, from its preset; nil for an endpoint with no preset.
    public static func providerID(_ kind: OopsCore.Provider.Kind) -> String? {
        guard case .api(let preset?) = kind else { return nil }
        return ["gemini": "google", "fireworks": "fireworks-ai", "together": "togetherai"][preset] ?? preset
    }
}

/// Decodes to nil instead of failing the whole feed.
struct Skippable<Value: Decodable & Sendable>: Decodable, Sendable {
    let value: Value?
    init(from decoder: any Decoder) throws { value = try? Value(from: decoder) }
}
