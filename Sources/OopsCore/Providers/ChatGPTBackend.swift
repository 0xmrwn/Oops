import Foundation

/// Corrections on the user's ChatGPT plan: the public Responses API with the sign-in's access token,
/// `store: false` and `stream: true` (OpenAI's models-and-inference and preview-limitations pages).
public struct ChatGPTBackend: CorrectionBackend {
    public let auth: ChatGPTAuth
    public let model: String
    public let effort: String?
    public let serviceTier: String?

    public init(auth: ChatGPTAuth, model: String, effort: String? = ModelSelection.defaultEffort, serviceTier: String? = nil) {
        self.auth = auth; self.model = model; self.effort = effort; self.serviceTier = serviceTier
    }

    public func complete(_ text: String, instructions: String) async throws -> String {
        do {
            try Task.checkCancellation()
            let (auth, model, effort, tier) = (auth, model, effort, serviceTier)
            return try await withDeadline(.seconds(40), orThrow: Self.slow) {
                try await auth.withAccessToken { token in
                    try await Responses.stream(request: Self.request(model: model, effort: effort, serviceTier: tier, instructions: instructions,
                                                                     text: text, token: token),
                                               session: auth.session)
                }
            }
        } catch { throw Self.friendly(error) }
    }

    /// Renews a token that is about to expire while the draft is still being read.
    public func prepare(instructions: String) async { _ = try? await auth.validAccessToken() }

    public static func request(model: String, effort: String?, serviceTier: String?, instructions: String, text: String,
                               token: String) throws -> URLRequest {
        try Responses.request(model: model, effort: effort, serviceTier: serviceTier, instructions: instructions, text: text, token: token)
    }

    static let slow = CorrectionError.failure(.slow, "ChatGPT took too long to correct this text. Try again.")
    private static let signIn = CorrectionError.failure(.signIn, "Sign in with ChatGPT in Settings.")

    /// Failures as the capsule names them. Messages are Oops's own; nothing the server sent is shown.
    static func friendly(_ error: Error) -> Error {
        if error is CancellationError || error is CorrectionError { return error }
        if let error = error as? URLError {
            if error.code == .cancelled { return CancellationError() }
            if error.code == .timedOut { return slow }
            return CorrectionError.failure(.offline, ChatGPTError.network.message)
        }
        guard let error = error as? ChatGPTError else { return CorrectionError.message("ChatGPT couldn’t complete this correction.") }
        if error.code == "cancelled" { return CancellationError() }
        if ["network_error", "stream_interrupted"].contains(error.code) {
            return CorrectionError.failure(.offline, "The connection to ChatGPT dropped. Check your connection and try again.")
        }
        if signInCodes.contains(error.code) || error.status == 401 { return signIn }
        if limitCodes.contains(error.code) || error.status == 429 { return CorrectionError.failure(.limit, error.message) }
        return CorrectionError.message(error.message)
    }

    /// Fixed by signing in again: the session ended, plan usage isn't allowed, or the permission was refused.
    private static let signInCodes: Set = [
        "sign_in_required", "sharing_not_enabled", "account_mismatch", "invalid_id_token", "invalid_client", "invalid_grant", "invalid_refresh_token",
        "token_expired", "refresh_token_expired", "refresh_token_invalidated", "refresh_token_reused", "subscription_sharing_invalid_user",
        "chatpass_v2_scope_not_authorized", "chatpass_v2_invalid_authorization_context", "storage_invalid",
    ]
    private static let limitCodes: Set = ["usage_limit_reached", "subscription_sharing_usage_limit_exceeded", "insufficient_quota", "rate_limit_exceeded"]
}
