import Foundation

/// A Sign in with ChatGPT failure: a machine code to branch on and a message written for people.
/// Messages are always Oops's own; text from OpenAI's servers is never shown, since it can echo the draft.
public struct ChatGPTError: LocalizedError, Equatable, Sendable {
    public let code: String
    public let message: String
    /// The HTTP status, when the failure came with one.
    public var status: Int?
    /// Worth trying again later with the same credentials (OpenAI's docs: "retry with bounded backoff").
    public var retryable: Bool

    public init(_ code: String, _ message: String, status: Int? = nil, retryable: Bool = false) {
        self.code = code; self.message = message; self.status = status; self.retryable = retryable
    }

    public var errorDescription: String? { message }

    /// The message Oops shows for a known code, or nil.
    static func known(_ code: String, status: Int? = nil) -> ChatGPTError? {
        guard let (message, retryable) = table[code] else { return nil }
        return ChatGPTError(code, message, status: status, retryable: retryable)
    }

    static func named(_ code: String, status: Int? = nil) -> ChatGPTError {
        known(code, status: status) ?? ChatGPTError(code, "ChatGPT couldn’t complete the request. Try again.", status: status)
    }

    public static let network = ChatGPTError("network_error", "Couldn’t reach ChatGPT. Check your connection and try again.", retryable: true)
    public static let signInRequired = ChatGPTError("sign_in_required", "Sign in with ChatGPT in Settings.")
    static let cancelled = ChatGPTError("cancelled", "Sign-in cancelled.")

    /// An error answer from the Responses API, the model catalog or a stream event. Reads only the
    /// machine-readable code: the `error.code` of a Responses error object, a top-level `code`, or an
    /// OAuth `error` string. A direct-admission body such as `{"detail": …}` has none, so its status decides.
    public static func api(_ body: Any?, status: Int?) -> ChatGPTError {
        let object = body as? [String: Any]
        let code = ((object?["error"] as? [String: Any])?["code"] as? String)
            ?? object?["code"] as? String ?? object?["error"] as? String
        if let code, let error = known(code, status: status) { return error }
        // An unlisted code stays as sent (errors-and-recovery: preserve it); the status picks the message.
        if let status, let error = byStatus(status) { return code.map { ChatGPTError($0, error.message, status: status, retryable: error.retryable) } ?? error }
        return named(code ?? "request_failed", status: status)
    }

    /// Direct-admission statuses from OpenAI's errors-and-recovery page, for answers without a known code.
    private static func byStatus(_ status: Int) -> ChatGPTError? {
        switch status {
        case 401: ChatGPTError("unauthorized", "ChatGPT didn’t accept this sign-in for the request. Sign in with ChatGPT in Settings.", status: status)
        case 403: ChatGPTError("forbidden", "ChatGPT refused this request, for example outside a supported region.", status: status)
        case 429: ChatGPTError("rate_limit_exceeded", "ChatGPT is limiting requests from Oops right now. Wait a moment, then try again.", status: status, retryable: true)
        case 503: ChatGPTError("service_unavailable", "ChatGPT plan usage is unavailable at the moment. Try again later.", status: status, retryable: true)
        case 500...599: ChatGPTError("server_error", "ChatGPT ran into a problem. Try again in a moment.", status: status, retryable: true)
        default: nil
        }
    }

    /// The codes OpenAI's errors-and-recovery page names, plus the ones Oops raises itself.
    private static let table: [String: (String, Bool)] = [
        // Sign-in and consent
        "access_denied": ("You didn’t allow Oops to use your ChatGPT plan. Continue with ChatGPT again whenever you want to allow it.", false),
        "sharing_not_enabled": ("You signed in, but Oops wasn’t allowed to use your ChatGPT plan. Continue with ChatGPT again and allow plan usage.", false),
        "registration_incomplete": ("ChatGPT didn’t finish setting up Oops. Continue with ChatGPT to try again.", false),
        "invalid_callback": ("The browser returned an incomplete sign-in. Continue with ChatGPT to try again.", false),
        "sign_in_timed_out": ("The sign-in took too long to finish in the browser. Continue with ChatGPT to start over.", false),
        "callback_unavailable": ("Oops couldn’t get ready for the browser’s answer. Try again.", true),
        "browser_unavailable": ("Oops couldn’t open your browser. Check your default browser, then try again.", false),
        "invalid_token_response": ("ChatGPT answered the sign-in in an unexpected way. Try again.", true),
        "invalid_id_token": ("Oops couldn’t confirm who signed in. Continue with ChatGPT to try again.", false),
        "identity_verification_unavailable": ("Oops can’t check your ChatGPT sign-in right now. Try again in a moment.", true),
        "account_mismatch": ("This isn’t the ChatGPT account Oops is connected to. Sign in with that account, or choose “Use a different account…” in Settings.", false),
        "revocation_unconfirmed": ("Oops signed out, but ChatGPT didn’t confirm it. To be sure, disconnect Oops in ChatGPT Settings.", false),
        // Refresh: an unusable refresh token means signing in again; an unknown client means registering again.
        "invalid_grant": ("Your ChatGPT sign-in has ended. Sign in with ChatGPT in Settings.", false),
        "invalid_refresh_token": ("Your ChatGPT sign-in has ended. Sign in with ChatGPT in Settings.", false),
        "token_expired": ("Your ChatGPT sign-in has ended. Sign in with ChatGPT in Settings.", false),
        "refresh_token_expired": ("Your ChatGPT sign-in has ended. Sign in with ChatGPT in Settings.", false),
        "refresh_token_invalidated": ("Your ChatGPT sign-in has ended. Sign in with ChatGPT in Settings.", false),
        "refresh_token_reused": ("Your ChatGPT sign-in has ended. Sign in with ChatGPT in Settings.", false),
        "refresh_deferred": ("ChatGPT asked Oops to wait before renewing your sign-in. Try again in a moment.", true),
        "invalid_client": ("ChatGPT no longer recognizes this copy of Oops. Sign in with ChatGPT in Settings to set it up again.", false),
        // Responses errors with a recovery of their own
        "subscription_sharing_user_not_eligible": ("Your ChatGPT account or workspace can’t share its plan with Oops.", false),
        "subscription_sharing_usage_limit_exceeded": ("You’ve reached a ChatGPT usage limit for Oops. Review it at chatgpt.com/settings/usage.", false),
        "usage_limit_reached": ("You’ve reached a ChatGPT usage limit for Oops. Review it at chatgpt.com/settings/usage.", false),
        "subscription_sharing_usage_unavailable": ("ChatGPT couldn’t check your plan’s usage just now. Try again shortly.", true),
        "subscription_sharing_unsupported_capability": ("Your ChatGPT plan can’t run this request with these options. Pick another model or turn off Fast in Settings.", false),
        "subscription_sharing_route_not_supported": ("Your ChatGPT plan can’t be used for this kind of request.", false),
        "subscription_sharing_invalid_user": ("ChatGPT couldn’t confirm your plan for this request. Sign in with ChatGPT in Settings.", false),
        "chatpass_v2_scope_not_authorized": ("ChatGPT didn’t authorize Oops for this request. Sign in with ChatGPT in Settings.", false),
        "chatpass_v2_invalid_authorization_context": ("ChatGPT didn’t authorize Oops for this request. Sign in with ChatGPT in Settings.", false),
        "subscription_sharing_user_unavailable": ("ChatGPT can’t load your account details right now. Try again in a few minutes.", true),
        "rate_limit_exceeded": ("ChatGPT is limiting requests from Oops right now. Wait a moment, then try again.", true),
        "model_not_found": ("This model isn’t available with your ChatGPT plan. Pick another one in Settings.", false),
        "models_unavailable": ("ChatGPT didn’t list any models for this account.", true),
        // Local storage
        "storage_failed": ("Oops couldn’t store your ChatGPT sign-in in the Keychain. Try again.", false),
        "storage_invalid": ("Oops’s saved ChatGPT sign-in is damaged. Sign in with ChatGPT in Settings.", false),
    ]
}
