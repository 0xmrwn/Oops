import Foundation

/// The ordinary OpenAI API connection: project key authentication, never ChatGPT token refresh.
public struct OpenAIResponsesBackend: CorrectionBackend {
    public let configuration: APIConfiguration
    private let session: URLSession
    public init(configuration: APIConfiguration, session: URLSession = .shared) {
        self.configuration = configuration; self.session = session
    }

    public func complete(_ text: String) async throws -> String {
        guard configuration.usesOpenAIResponses, !configuration.model.trimmingCharacters(in: .whitespaces).isEmpty,
              !configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CorrectionError.failure(.setup, "Set the OpenAI API endpoint, key and model in Settings.")
        }
        do {
            try Task.checkCancellation()
            let effort = OpenAIReasoning.effort(model: configuration.model, selected: configuration.reasoningEffort)
            let request = try Responses.request(model: configuration.model, effort: effort,
                                                serviceTier: nil, text: text, token: configuration.apiKey)
            let raw = try await withDeadline(.seconds(40), orThrow: Self.slow) {
                try await Responses.stream(request: request, session: session)
            }
            try Task.checkCancellation()
            return raw
        } catch { throw Self.friendly(error) }
    }

    static let slow = CorrectionError.failure(.slow, "OpenAI API took too long to correct this text. Try again.")

    static func friendly(_ error: Error) -> Error {
        if error is CancellationError || error is CorrectionError { return error }
        if let error = error as? URLError {
            if error.code == .cancelled { return CancellationError() }
            if error.code == .timedOut { return slow }
            return CorrectionError.failure(.offline, "Couldn't reach the OpenAI API. Check your connection and try again.")
        }
        // The shared parser reads machine codes only. Its subscription-specific messages never escape here.
        guard let error = error as? ChatGPTError else { return CorrectionError.message("OpenAI API could not complete this correction.") }
        if ["invalid_api_key", "invalid_token", "token_expired"].contains(error.code) || error.status == 401 {
            return CorrectionError.failure(.setup, "OpenAI API rejected the API key. Update it in Settings.")
        }
        if ["insufficient_quota", "usage_limit_reached", "rate_limit_exceeded"].contains(error.code) || error.status == 429 {
            return CorrectionError.failure(.limit, "OpenAI API usage limit reached. Check your API billing and usage at platform.openai.com.")
        }
        if ["network_error", "stream_interrupted"].contains(error.code) {
            return CorrectionError.failure(.offline, "The connection to the OpenAI API was interrupted. Try again.")
        }
        if [400, 403, 404, 422].contains(error.status) || ["model_not_found", "permission_denied"].contains(error.code) {
            return CorrectionError.failure(.setup, "OpenAI API rejected the request. Check the API key, model access and options in Settings.")
        }
        return CorrectionError.message("OpenAI API did not return a complete structured correction. Nothing replaced.")
    }
}

public extension Provider {
    func apiBackend(model: String, apiKey: String, effort: String? = nil, session: URLSession = .shared) throws -> any CorrectionBackend {
        guard case .api = kind, let url = URL(string: baseURL ?? ""), APIConfiguration.isSafe(url), url.host != nil else {
            throw CorrectionError.failure(.setup, "Enter the endpoint for \(name) in Settings.")
        }
        return APIConfiguration(baseURL: url, model: model, apiKey: apiKey, reasoningEffort: effort).backend(session: session)
    }
}
