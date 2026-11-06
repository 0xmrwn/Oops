import Foundation
import Security
import Synchronization

/// Sign in with ChatGPT, as OpenAI documents it for open-source apps (developers.openai.com/siwc/
/// token-sharing-open-source): a browser sign-in that registers Oops for the user's ChatGPT plan, then
/// access tokens that refresh themselves. One instance per process; corrections and Settings share it.
public final class ChatGPTAuth: @unchecked Sendable {
    public typealias OpenBrowser = @Sendable (URL) async throws -> Void

    let store: ChatGPTStore
    public let session: URLSession
    private let openBrowser: OpenBrowser
    private let gate = SerialGate()
    private let lock = NSLock()
    private var cachedDiscovery: Discovery?
    private var keys: [String: SecKey] = [:]
    private var attempt: LoopbackCallback?

    #if DEBUG
    func queuedRefreshes() async -> Int { await gate.waiterCount }
    #endif

    /// No cookies or cache: nothing about the sign-in outlives the request that needed it.
    public static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    public init(store: ChatGPTStore = ChatGPTKeychainStore(), session: URLSession = ChatGPTAuth.defaultSession, openBrowser: @escaping OpenBrowser) {
        self.store = store; self.session = session; self.openBrowser = openBrowser
    }

    // MARK: Sign-in

    /// Runs one browser sign-in to completion. A returning account reuses its issued client ID, and new
    /// credentials replace the old ones only once their identity and plan permission check out.
    /// Returns the verified identity after the profile and credentials are saved.
    @discardableResult public func signIn() async throws -> ChatGPTIdentity {
        var profile = try store.readProfile() ?? .newHost()
        try store.writeProfile(profile)
        let discovery = try await discover()
        let state = Self.randomValue(), nonce = Self.randomValue(), verifier = Self.randomValue()
        let callback = LoopbackCallback(state: state, savedClientID: profile.clientID)
        let previous = lock.withLock { defer { attempt = callback }; return attempt }
        previous?.cancel()
        defer {
            lock.withLock { if attempt === callback { attempt = nil } }
            callback.cancel()
        }
        let port: Int
        do { port = try await callback.start() } catch { throw ChatGPTError.named("callback_unavailable") }
        let redirect = "http://127.0.0.1:\(port)\(Self.callbackPath)"
        let saved = (try? store.readCredentials()) ?? nil
        let url = Self.authorizationURL(endpoint: discovery.authorization, clientID: profile.clientID, redirect: redirect, state: state, nonce: nonce,
                                        verifier: verifier, hostID: profile.hostID, loginHint: profile.identity?.email,
                                        idTokenHint: saved?.clientID == profile.clientID ? saved?.idToken : nil,
                                        consent: profile.consentNeeded == true, appName: Self.appName)
        try await openBrowser(url)

        let outcome = try await withDeadline(.seconds(600), orThrow: ChatGPTError.named("sign_in_timed_out")) { try await callback.wait() }
        let code: String, clientID: String
        switch outcome {
        case let .success(returned, issued): (code, clientID) = (returned, issued)
        case let .failure(error):
            // Declined consent: the next sign-in with this registration asks for it again (errors-and-recovery).
            if error.code == "access_denied", profile.clientID != nil { profile.consentNeeded = true; try? store.writeProfile(profile) }
            throw error
        }
        // The registration exists once ChatGPT issues its client ID: keep it for the next attempt.
        if profile.clientID == nil { try ensureCurrent(callback); profile.clientID = clientID; try store.writeProfile(profile) }

        let (status, body) = try await post(discovery.token, [
            ("grant_type", "authorization_code"), ("client_id", clientID), ("code", code), ("code_verifier", verifier),
            ("redirect_uri", redirect), ("resource", Self.resource),
        ])
        guard status == 200, let body else {
            // A spent or expired code can't be retried; only a fresh authorization helps.
            if body?["error"] as? String == "invalid_grant" {
                throw ChatGPTError("invalid_grant", "The sign-in expired before it finished. Continue with ChatGPT to try again.", status: status)
            }
            throw Self.tokenEndpointError(status, body)
        }
        let (scopes, tokens) = try Self.grant(body, requireRefresh: false, now: Date())
        guard let idToken = body["id_token"] as? String else { throw ChatGPTError.named("invalid_token_response") }
        let (subject, identity) = try await verify(idToken, clientID: clientID, nonce: nonce, discovery: discovery)
        if let known = profile.subject, known != subject { throw ChatGPTError.named("account_mismatch") }
        profile.subject = subject; profile.identity = identity

        // A valid ID token alone doesn't allow plan usage: the grant must carry the direct scope.
        guard scopes.contains(Self.directScope) else {
            try ensureCurrent(callback)
            profile.state = .disconnected; profile.consentNeeded = true
            try store.writeProfile(profile)
            try? store.deleteCredentials()
            if let refresh = tokens.refreshToken { _ = await revoke(refresh, clientID: clientID, retries: 0) }
            throw ChatGPTError.named("sharing_not_enabled")
        }
        guard tokens.refreshToken != nil else { throw ChatGPTError.named("invalid_token_response") }
        try await serialized {
            // Checked under the same lock sign-out takes: a sign-out or newer attempt since the callback wins.
            try ensureCurrent(callback)
            try store.writeCredentials(ChatGPTCredentials(clientID: clientID, scopes: scopes, idToken: idToken, tokens: tokens))
            profile.state = .connected; profile.consentNeeded = nil
            try store.writeProfile(profile)
        }
        // The session this sign-in replaced is no longer needed.
        if let old = saved?.pending?.tokens.refreshToken ?? saved?.tokens.refreshToken, old != tokens.refreshToken, let saved {
            _ = await revoke(old, clientID: saved.clientID, retries: 0)
        }
        return identity
    }

    /// Fails once `callback`'s attempt was cancelled or replaced, so it never writes over what came after it.
    private func ensureCurrent(_ callback: LoopbackCallback) throws {
        guard lock.withLock({ attempt === callback }), !Task.isCancelled else { throw ChatGPTError.cancelled }
    }

    public func cancelSignIn() {
        let current = lock.withLock { defer { attempt = nil }; return attempt }
        current?.cancel()
    }

    /// Revokes the renewable session and clears the tokens. The registration and host ID stay, so the
    /// next sign-in reuses them; `forgetAccount` also drops the registration, so another account can
    /// register (the host ID still stays). Throws `revocation_unconfirmed` after signing out locally
    /// when ChatGPT didn't confirm the revocation.
    public func signOut(forgetAccount: Bool = false) async throws {
        cancelSignIn()
        let confirmed: Bool = try await serialized {
            var confirmed = true
            if let credentials = (try? store.readCredentials()) ?? nil,
               let refresh = credentials.pending?.tokens.refreshToken ?? credentials.tokens.refreshToken {
                confirmed = await revoke(refresh, clientID: credentials.clientID, retries: 2)
            }
            try store.deleteCredentials()
            if var profile = try store.readProfile() {
                profile.state = .disconnected
                if forgetAccount { profile.clientID = nil; profile.subject = nil; profile.identity = nil; profile.consentNeeded = nil }
                try store.writeProfile(profile)
            }
            return confirmed
        }
        if !confirmed { throw ChatGPTError.named("revocation_unconfirmed") }
    }

    // MARK: Access tokens

    /// The current access token, refreshed first when it is close to expiry.
    public func validAccessToken() async throws -> String { try await token(rejecting: nil) }

    /// Runs `body` with an access token. A 401 doesn't by itself mean the session ended, so the token is
    /// refreshed and `body` runs once more, never more.
    public func withAccessToken<T>(_ body: (String) async throws -> T) async throws -> T {
        let token = try await validAccessToken()
        // Finish saving a rotation, but never start a request for its cancelled caller.
        try Task.checkCancellation()
        do { return try await body(token) } catch let error as ChatGPTError where error.status == 401 {
            let renewed = try await self.token(rejecting: token)
            try Task.checkCancellation()
            return try await body(renewed)
        }
    }

    private func token(rejecting rejected: String?) async throws -> String {
        try Task.checkCancellation()
        let cancelled = Mutex(false)
        let check: @Sendable () throws -> Void = {
            if cancelled.withLock({ $0 }) { throw CancellationError() }
        }
        return try await withTaskCancellationHandler {
            try await Task {
                try await self.serialized(check: check) {
                    guard var credentials = try self.store.readCredentials() else { throw ChatGPTError.signInRequired }
                    if let pending = credentials.pending { credentials = try await self.adopt(pending, into: credentials) }
                    let tokens = credentials.tokens, left = tokens.expiresAt.timeIntervalSinceNow
                    let usable = tokens.accessToken != rejected && left > 5
                    if usable, left > 120 { return tokens.accessToken }
                    // Never refresh before the server's `earliest_refresh_at`: a valid token serves until then.
                    if let earliest = tokens.earliestRefreshAt, earliest > Date() {
                        if usable { return tokens.accessToken }
                        throw ChatGPTError.named("refresh_deferred")
                    }
                    return try await self.refresh(credentials, check: check)
                }
            }.value
        } onCancel: { cancelled.withLock { $0 = true } }
    }

    /// One refresh at a time, in this process and across processes sharing the store: the refresh
    /// token rotates, and the second of two racing refreshes would spend a dead one.
    private func serialized<T: Sendable>(check: () throws -> Void = {}, _ body: () async throws -> T) async throws -> T {
        await gate.enter()
        do {
            try check()
            let value = try await store.exclusively {
                try check()
                return try await body()
            }
            await gate.leave()
            return value
        } catch {
            await gate.leave()
            throw error
        }
    }

    private func refresh(_ credentials: ChatGPTCredentials, check: () throws -> Void) async throws -> String {
        try check()
        guard let refreshToken = credentials.tokens.refreshToken else {
            try endSession()
            throw ChatGPTError.named("invalid_grant")
        }
        let discovery = try await discover()
        // Commit here, before transport. Finish and save the rotation even if cancelled later.
        try check()
        // `scope` is left out so the grant stays as it was (profiles-and-sessions: refreshing tokens).
        let (status, body) = try await post(discovery.token, [
            ("grant_type", "refresh_token"), ("client_id", credentials.clientID), ("refresh_token", refreshToken), ("resource", Self.resource),
        ])
        guard status == 200, let body else {
            let code = body?["error"] as? String
            if let code, Self.endsSession.contains(code) {
                try endSession(forgetClient: code == "invalid_client")
                throw ChatGPTError.named(code, status: status)
            }
            throw Self.tokenEndpointError(status, body)
        }
        var (scopes, tokens) = try Self.grant(body, requireRefresh: false, previousScopes: credentials.scopes, now: Date())
        // RFC 6749 §6: without a replacement, the current refresh token stays valid.
        if tokens.refreshToken == nil { tokens.refreshToken = refreshToken }
        var updated = credentials
        if let idToken = body["id_token"] as? String {
            // Saved before verification: the old refresh token is spent, and this answer is the only way on.
            let pending = ChatGPTCredentials.Pending(tokens: tokens, scopes: scopes, idToken: idToken, receivedAt: Date())
            updated.pending = pending
            try store.writeCredentials(updated)
            updated = try await adopt(pending, into: updated)
        } else {
            updated.tokens = tokens; updated.scopes = scopes; updated.pending = nil
            try requirePlanScope(updated.scopes)
            try store.writeCredentials(updated)
        }
        return updated.tokens.accessToken
    }

    /// Verifies a refreshed ID token, as of when it arrived, and only then puts its tokens in use.
    private func adopt(_ pending: ChatGPTCredentials.Pending, into credentials: ChatGPTCredentials) async throws -> ChatGPTCredentials {
        let (subject, identity): (String, ChatGPTIdentity)
        do { (subject, identity) = try await verify(pending.idToken, clientID: credentials.clientID, nonce: nil, at: pending.receivedAt) } catch let error as ChatGPTError where error.code == "invalid_id_token" {
            try endSession()
            throw error
        }
        let profile = try store.readProfile()
        if let known = profile?.subject, known != subject {
            try endSession()
            throw ChatGPTError.named("account_mismatch")
        }
        var adopted = credentials
        adopted.tokens = pending.tokens; adopted.scopes = pending.scopes; adopted.idToken = pending.idToken; adopted.pending = nil
        try requirePlanScope(adopted.scopes)
        try store.writeCredentials(adopted)
        if var profile, profile.identity != identity { profile.identity = identity; try? store.writeProfile(profile) }
        return adopted
    }

    private func requirePlanScope(_ scopes: [String]) throws {
        guard !scopes.contains(Self.directScope) else { return }
        try endSession(consent: true)
        throw ChatGPTError.named("sharing_not_enabled")
    }

    /// The tokens are unusable: clear them and ask for a new sign-in (errors-and-recovery: refresh errors).
    private func endSession(forgetClient: Bool = false, consent: Bool = false) throws {
        try store.deleteCredentials()
        guard var profile = try store.readProfile() else { return }
        profile.state = .reauthRequired
        if forgetClient { profile.clientID = nil }
        if consent { profile.consentNeeded = true }
        try store.writeProfile(profile)
    }

    /// Refresh errors that mean the tokens, or the client itself, can't be used again.
    private static let endsSession: Set = ["invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired",
                                           "refresh_token_invalidated", "refresh_token_reused", "invalid_client"]

    // MARK: Endpoints

    private func discover() async throws -> Discovery {
        if let cached = lock.withLock({ cachedDiscovery }) { return cached }
        let (status, body) = try await send(URLRequest(url: Self.discoveryURL, timeoutInterval: 15))
        guard status == 200, let body else { throw ChatGPTError.named("identity_verification_unavailable", status: status) }
        let discovery = try Self.discovery(body)
        lock.withLock { cachedDiscovery = discovery }
        return discovery
    }

    /// The signing key for `token` from OpenAI's JWKS, fetched again when an unfamiliar key appears.
    private func verify(_ token: String, clientID: String, nonce: String?, discovery: Discovery? = nil, at time: Date = Date()) async throws -> (String, ChatGPTIdentity) {
        let kid = Self.keyID(token)
        func key(in keys: [String: SecKey]) -> SecKey? { kid.flatMap { keys[$0] } ?? (kid == nil && keys.count == 1 ? keys.values.first : nil) }
        var found = key(in: lock.withLock { keys })
        if found == nil {
            let unavailable = ChatGPTError.named("identity_verification_unavailable")
            var endpoint = discovery?.jwks
            if endpoint == nil { endpoint = try? await discover().jwks }
            guard let endpoint, let answer = try? await send(URLRequest(url: endpoint, timeoutInterval: 15)),
                  answer.0 == 200, let body = answer.1 else { throw unavailable }
            let fetched = Self.jwks(body)
            lock.withLock { keys = fetched }
            found = key(in: fetched)
        }
        guard let found else { throw ChatGPTError.named("invalid_id_token") }
        return try Self.verifyIDToken(token, key: found, clientID: clientID, nonce: nonce, now: time)
    }

    /// RFC 7009 revocation, retried with backoff on network and server failures (profiles-and-sessions).
    private func revoke(_ token: String, clientID: String, retries: Int) async -> Bool {
        guard let endpoint = try? await discover().revocation else { return false }
        for attempt in 0...retries {
            if attempt > 0 { try? await Task.sleep(for: .milliseconds(500 * attempt)) }
            guard let status = try? await post(endpoint, [("token", token), ("token_type_hint", "refresh_token"), ("client_id", clientID)]).0 else { continue }
            if status == 200 { return true }
            if status < 500 { return false }
        }
        return false
    }

    private static func tokenEndpointError(_ status: Int, _ body: [String: Any]?) -> ChatGPTError {
        if let code = body?["error"] as? String, let known = ChatGPTError.known(code, status: status) { return known }
        if status >= 500 { return ChatGPTError("server_error", "ChatGPT’s sign-in service had a problem. Try again in a moment.", status: status, retryable: true) }
        return ChatGPTError.named("invalid_token_response", status: status)
    }

    private func post(_ url: URL, _ form: [(String, String)]) async throws -> (Int, [String: Any]?) {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(Self.encode(form).utf8)
        return try await send(request)
    }

    /// JSON in, status and JSON object out; transport failures read as `network_error`.
    func send(_ request: URLRequest) async throws -> (Int, [String: Any]?) {
        var request = request
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request, delegate: NoRedirect.shared) } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch { throw ChatGPTError.network }
        guard let http = response as? HTTPURLResponse else { throw ChatGPTError.network }
        return (http.statusCode, try? JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
