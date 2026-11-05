import CryptoKit
import Foundation
import Security

// The wire contract of Sign in with ChatGPT for open-source apps, as OpenAI documents it at
// developers.openai.com/siwc/token-sharing-open-source (sign-in, profiles-and-sessions, token-reference),
// on top of OAuth 2.0 (RFC 6749), PKCE (RFC 7636), native-app loopback redirects (RFC 8252) and
// OpenID Connect Core and Discovery.
extension ChatGPTAuth {
    static let issuer = "https://auth.openai.com"
    static let discoveryURL = URL(string: "https://auth.openai.com/.well-known/openid-configuration")!
    /// The audience of every token request.
    static let resource = "https://api.openai.com/v1"
    /// Identity scopes, then the ChatGPT plan usage scopes.
    public static let scopes = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
    /// The scope that actually authorizes plan usage; a valid ID token alone does not.
    static let directScope = "chatgpt.tokens.use.direct"
    /// First-time registration entry point: never saved, never used for a token exchange.
    static let registrationClient = "dynamic_agent_client"
    static let callbackPath = "/auth/callback"
    /// Sent as `agent_name_hint` on a first registration; the user can rename it before approving.
    static let appName = "Oops"

    struct Discovery: Sendable { let authorization: URL, token: URL, revocation: URL?, jwks: URL }

    /// The authorization request. A new registration names the app and uses `dynamic_agent_client`; a
    /// returning one uses its issued client ID with the retained hints. `ext_agent_host_id` is required on both.
    static func authorizationURL(endpoint: URL, clientID: String?, redirect: String, state: String, nonce: String, verifier: String,
                                 hostID: String, loginHint: String?, idTokenHint: String? = nil, consent: Bool = false, appName: String) -> URL {
        var items: [(String, String)] = [
            ("response_type", "code"), ("client_id", clientID ?? registrationClient), ("redirect_uri", redirect),
            ("scope", scopes), ("resource", resource), ("state", state), ("nonce", nonce),
            ("code_challenge", challenge(verifier)), ("code_challenge_method", "S256"), ("ext_agent_host_id", hostID),
        ]
        if clientID == nil { items.append(("agent_name_hint", appName)) }
        if clientID != nil, let idTokenHint { items.append(("id_token_hint", idTokenHint)) }
        if clientID != nil, let loginHint, !loginHint.isEmpty { items.append(("login_hint", loginHint)) }
        // Asking again after plan usage was declined; never on an ordinary sign-in (errors-and-recovery).
        if consent { items.append(("prompt", "consent")) }
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.percentEncodedQuery = encode(items)
        return components.url!
    }

    /// Form and query encoding that leaves only RFC 3986 unreserved characters bare, so `+` and `@`
    /// survive the trip (a bare `+` would read back as a space).
    static func encode(_ items: [(String, String)]) -> String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return items.map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "")" }.joined(separator: "&")
    }

    /// 32 random bytes, base64url: a PKCE verifier (43 characters, within RFC 7636's 43–128), state or nonce.
    static func randomValue() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "no system randomness")
        return base64URL(Data(bytes))
    }

    /// The S256 code challenge: base64url SHA-256 of the verifier, without padding.
    static func challenge(_ verifier: String) -> String { base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))) }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func base64URLDecode(_ text: Substring) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }

    /// Validates a token-endpoint answer (RFC 6749 §5.1) and returns its granted scopes and tokens.
    /// `scope` may be omitted only when it repeats an earlier grant (`previousScopes`, on refresh). With
    /// `offline_access` granted, or `requireRefresh`, a refresh token must come with it (token-reference).
    static func grant(_ object: [String: Any], requireRefresh: Bool, previousScopes: [String]? = nil,
                      now: Date) throws -> (scopes: [String], tokens: ChatGPTTokens) {
        let invalid = ChatGPTError.named("invalid_token_response")
        guard let access = object["access_token"] as? String, !access.isEmpty,
              (object["token_type"] as? String)?.lowercased() == "bearer",
              let lifetime = (object["expires_in"] as? NSNumber)?.doubleValue, lifetime > 0 else { throw invalid }
        let scopes: [String]
        if let scope = object["scope"] as? String {
            scopes = scope.split(separator: " ").map(String.init)
        } else if let previousScopes {
            scopes = previousScopes
        } else { throw invalid }
        let refresh = object["refresh_token"] as? String
        if refresh?.isEmpty ?? true, requireRefresh || (object["scope"] != nil && scopes.contains("offline_access")) { throw invalid }
        let tokens = ChatGPTTokens(accessToken: access, refreshToken: refresh?.isEmpty == false ? refresh : nil,
                                   expiresAt: now.addingTimeInterval(lifetime), earliestRefreshAt: earliestRefresh(object["earliest_refresh_at"]))
        return (scopes, tokens)
    }

    /// The token reference names `earliest_refresh_at` without a format: Unix seconds or an ISO 8601
    /// date are read; anything else sets no constraint.
    private static func earliestRefresh(_ value: Any?) -> Date? {
        if let seconds = (value as? NSNumber)?.doubleValue, seconds > 0 { return Date(timeIntervalSince1970: seconds) }
        guard let text = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }

    /// The discovery document, with its issuer and endpoints pinned to auth.openai.com over HTTPS.
    static func discovery(_ object: [String: Any]) throws -> Discovery {
        func endpoint(_ key: String) -> URL? {
            guard let text = object[key] as? String, let url = URL(string: text), url.scheme == "https", url.host == "auth.openai.com" else { return nil }
            return url
        }
        guard object["issuer"] as? String == issuer, let authorization = endpoint("authorization_endpoint"),
              let token = endpoint("token_endpoint"), let jwks = endpoint("jwks_uri") else { throw ChatGPTError.named("identity_verification_unavailable") }
        return Discovery(authorization: authorization, token: token, revocation: endpoint("revocation_endpoint"), jwks: jwks)
    }
}
