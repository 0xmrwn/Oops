import Foundation

public struct APIConfiguration: Sendable {
    public let baseURL: URL
    public let model: String
    public let apiKey: String
    /// Sent as `reasoning_effort` only when set; most providers reject values they don't know.
    public let reasoningEffort: String?
    public init(baseURL: URL, model: String, apiKey: String = "", reasoningEffort: String? = nil) {
        self.baseURL = baseURL; self.model = model; self.apiKey = apiKey; self.reasoningEffort = reasoningEffort
    }
    /// HTTPS, or HTTP only on this Mac; no credentials, query or fragment that could leak.
    public static func isSafe(_ baseURL: URL) -> Bool {
        let local = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(baseURL.host ?? "")
        return (baseURL.scheme == "https" || (local && baseURL.scheme == "http"))
            && baseURL.user == nil && baseURL.password == nil && baseURL.query == nil && baseURL.fragment == nil
    }
    /// Only the official validated base selects Responses; names and preset marks can be edited.
    public var usesOpenAIResponses: Bool {
        Self.isSafe(baseURL) && baseURL.host?.lowercased() == "api.openai.com"
            && (baseURL.port == nil || baseURL.port == 443) && ["/v1", "/v1/"].contains(baseURL.path)
    }

    public func backend(session: URLSession = .shared) -> any CorrectionBackend {
        if usesOpenAIResponses { return OpenAIResponsesBackend(configuration: self, session: session) }
        return OpenAICompatibleBackend(configuration: self, session: session)
    }

    public func request(for text: String) throws -> URLRequest {
        guard Self.isSafe(baseURL), !model.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw CorrectionError.message("Use an HTTPS base URL (or local HTTP) and a model name.")
        }
        var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 35
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        var body: [String: Any] = [
            "model": model, "stream": false,
            "messages": [["role": "system", "content": CorrectionPolicy.instructions], ["role": "user", "content": text]],
            "response_format": ["type": "json_schema", "json_schema": ["name": "correction", "strict": true, "schema": CorrectionPolicy.schema]]
        ]
        if let reasoningEffort { body["reasoning_effort"] = reasoningEffort }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
}

public struct OpenAICompatibleBackend: CorrectionBackend {
    public let configuration: APIConfiguration
    private let session: URLSession
    public init(configuration: APIConfiguration, session: URLSession = .shared) {
        self.configuration = configuration; self.session = session
    }
    public func complete(_ text: String) async throws -> String {
        let data: Data, response: URLResponse
        let request = try configuration.request(for: text), session = session
        // The request timeout only bounds silence between bytes; the deadline bounds the whole answer.
        do { (data, response) = try await withDeadline(.seconds(40), orThrow: URLError(.timedOut)) { try await session.data(for: request) } }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch let error as URLError where error.code == .timedOut { throw CorrectionError.failure(.slow, "The API took too long to correct this text. Try again.") }
        catch is URLError { throw CorrectionError.failure(.offline, "Couldn't reach the API. Check your connection and try again.") }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw CorrectionError.message("No response from the API.") }
        guard http.statusCode == 200 else {
            // Provider error bodies can echo prompts or credentials. Never surface them verbatim.
            let message = "API returned HTTP \(http.statusCode). Check the endpoint, key, model and JSON-schema support."
            switch http.statusCode {
            case 401, 403, 404: throw CorrectionError.failure(.setup, message)
            case 429: throw CorrectionError.failure(.limit, message)
            default: throw CorrectionError.message(message)
            }
        }
        guard data.count <= 256_000,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]], choices.count == 1,
              choices[0]["finish_reason"] as? String == "stop",
              let message = choices[0]["message"] as? [String: Any],
              message["refusal"] == nil || message["refusal"] is NSNull,
              message["tool_calls"] == nil || message["tool_calls"] is NSNull,
              let raw = message["content"] as? String else {
            throw CorrectionError.message("The API did not return one complete structured correction.")
        }
        return raw
    }
}

public struct OpenAICompatibleModel: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
}

/// The provider's own catalog from `GET <base>/models`; oops never ships one.
public enum OpenAICompatibleModels {
    public static func decode(_ data: Data) throws -> [OpenAICompatibleModel] {
        let invalid = CorrectionError.message("The provider returned an unexpected model list.")
        guard data.count <= 4_000_000, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = object["data"] as? [Any] else { throw invalid }
        func text(_ value: Any?) -> String? {
            guard let value = (value as? String)?.trimmingCharacters(in: .whitespaces), !value.isEmpty, value.count <= 200 else { return nil }
            return value
        }
        var seen = Set<String>()
        let models = entries.compactMap { entry -> OpenAICompatibleModel? in
            // Some servers list `models/<id>`, but chat completions take the bare ID.
            guard let entry = entry as? [String: Any], let raw = text(entry["id"]),
                  let id = text(raw.hasPrefix("models/") ? String(raw.dropFirst(7)) : raw), seen.insert(id).inserted else { return nil }
            return OpenAICompatibleModel(id: id, name: text(entry["display_name"]) ?? id)
        }
        guard !models.isEmpty else { throw CorrectionError.message("The provider listed no models.") }
        return models
    }

    public static func list(baseURL: URL, apiKey: String = "", session: URLSession = .shared) async throws -> [OpenAICompatibleModel] {
        guard APIConfiguration.isSafe(baseURL) else { throw CorrectionError.message("Use an HTTPS base URL (or local HTTP).") }
        var request = URLRequest(url: baseURL.appendingPathComponent("models"), timeoutInterval: 30)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        let checkedRequest = request
        let data: Data, response: URLResponse
        do {
            (data, response) = try await withDeadline(.seconds(30), orThrow: URLError(.timedOut)) {
                try await session.data(for: checkedRequest)
            }
        } catch let error as URLError where error.code == .timedOut {
            throw CorrectionError.message("The provider took too long to list models. Try again.")
        } catch let error as URLError where error.code != .cancelled { throw CorrectionError.message("Couldn't reach the provider.") }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw CorrectionError.message("No response from the provider.") }
        // Error bodies can echo the key or request. Never surface them.
        switch http.statusCode {
        case 200: return try decode(data)
        case 401, 403: throw CorrectionError.message("The provider rejected the API key.")
        // Some providers answer a bad key on this route with 400 rather than 401.
        case 400: throw CorrectionError.message("The provider rejected the request. Check the API key and endpoint.")
        case 404: throw CorrectionError.message("No model list at this endpoint. Check the address.")
        default: throw CorrectionError.message("The provider returned HTTP \(http.statusCode) for the model list.")
        }
    }
}

/// A popular OpenAI-compatible service: only what stays true for years (name, mark, public endpoint).
/// Never models: those always come from the provider's own `/models`.
public struct ProviderPreset: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let logoAsset: String
    public let endpoint: URL
    /// Servers running on this Mac, which take no key by default.
    public let local: Bool

    /// Alphabetical; servers on this Mac sit with the rest, since they are APIs all the same.
    public static let all = [
        ProviderPreset("cerebras", "Cerebras", "CerebrasMark", "https://api.cerebras.ai/v1"),
        ProviderPreset("deepseek", "DeepSeek", "DeepSeekMark", "https://api.deepseek.com/v1"),
        ProviderPreset("fireworks", "Fireworks AI", "FireworksMark", "https://api.fireworks.ai/inference/v1"),
        ProviderPreset("gemini", "Gemini", "GeminiMark", "https://generativelanguage.googleapis.com/v1beta/openai"),
        ProviderPreset("groq", "Groq", "GroqMark", "https://api.groq.com/openai/v1"),
        ProviderPreset("lmstudio", "LM Studio", "LMStudioMark", "http://localhost:1234/v1", local: true),
        ProviderPreset("mistral", "Mistral", "MistralMark", "https://api.mistral.ai/v1"),
        ProviderPreset("ollama", "Ollama", "OllamaMark", "http://localhost:11434/v1", local: true),
        ProviderPreset("openai", "OpenAI", "OpenAIMark", "https://api.openai.com/v1"),
        ProviderPreset("openrouter", "OpenRouter", "OpenRouterMark", "https://openrouter.ai/api/v1"),
        ProviderPreset("together", "Together AI", "TogetherMark", "https://api.together.xyz/v1"),
        ProviderPreset("xai", "xAI", "XAIMark", "https://api.x.ai/v1"),
    ]

    public init?(id: String) {
        guard let preset = Self.all.first(where: { $0.id == id }) else { return nil }
        self = preset
    }

    init(_ id: String, _ name: String, _ logoAsset: String, _ endpoint: String, local: Bool = false) {
        self.id = id; self.name = name; self.logoAsset = logoAsset; self.endpoint = URL(string: endpoint)!; self.local = local
    }
}
