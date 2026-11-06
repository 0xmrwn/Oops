import CryptoKit
import XCTest
@testable import OopsCore

final class ChatGPTAuthTests: XCTestCase {
    private func query(_ url: URL) -> [String: String] {
        Dictionary((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") }) { a, _ in a }
    }

    func testAuthorizeURLCarriesPKCEStateNonceScopesHostAndNameHintOnlyForNewRegistration() {
        let endpoint = URL(string: "https://auth.openai.com/oauth/authorize")!
        let fresh = ChatGPTAuth.authorizationURL(endpoint: endpoint, clientID: nil, redirect: "http://127.0.0.1:4321/auth/callback",
                                                 state: "state-1", nonce: "nonce-1", verifier: "verifier-1", hostID: "urn:uuid:fresh", loginHint: "a@example.invalid", idTokenHint: "old.id.token", appName: "Oops")
        let q = query(fresh)
        XCTAssertEqual(q["client_id"], "dynamic_agent_client")
        XCTAssertEqual(q["agent_name_hint"], "Oops")
        XCTAssertEqual(q["response_type"], "code")
        XCTAssertEqual(q["redirect_uri"], "http://127.0.0.1:4321/auth/callback")
        XCTAssertEqual(Set(q["scope"]!.split(separator: " ")), ["openid", "profile", "email", "offline_access", "resource.invoke", "chatgpt.tokens.use.direct"])
        XCTAssertEqual(q["resource"], "https://api.openai.com/v1")
        XCTAssertEqual(q["state"], "state-1")
        XCTAssertEqual(q["nonce"], "nonce-1")
        XCTAssertEqual(q["code_challenge_method"], "S256")
        XCTAssertEqual(q["code_challenge"], ChatGPTAuth.base64URL(Data(SHA256.hash(data: Data("verifier-1".utf8)))))
        XCTAssertEqual(q["ext_agent_host_id"], "urn:uuid:fresh", "required on every authorization request")
        XCTAssertNil(q["login_hint"]); XCTAssertNil(q["id_token_hint"], "hints identify a registered account only"); XCTAssertNil(q["prompt"])

        let again = ChatGPTAuth.authorizationURL(endpoint: endpoint, clientID: "client_issued", redirect: "http://127.0.0.1:1/auth/callback",
                                                 state: "s", nonce: "n", verifier: "v", hostID: "urn:uuid:x", loginHint: "a+b@example.invalid",
                                                 idTokenHint: "old.id.token", consent: true, appName: "Oops")
        let r = query(again)
        XCTAssertEqual(r["client_id"], "client_issued")
        XCTAssertNil(r["agent_name_hint"])
        XCTAssertEqual(r["ext_agent_host_id"], "urn:uuid:x")
        XCTAssertEqual(r["id_token_hint"], "old.id.token"); XCTAssertEqual(r["prompt"], "consent")
        XCTAssertTrue(again.absoluteString.contains("login_hint=a%2Bb%40example.invalid"), "'+' must not decode as a space")
        let verifier = ChatGPTAuth.randomValue()
        XCTAssertEqual(verifier.count, 43); XCTAssertNil(verifier.rangeOfCharacter(from: CharacterSet(charactersIn: "+/=")))
    }

    func testCallbackRejectsWrongStateErrorsAndMissingIssuedClient() {
        func handle(_ target: String, host: String = "127.0.0.1:4321", saved: String? = nil) -> LoopbackCallback.Reply {
            LoopbackCallback.handle(head: "GET \(target) HTTP/1.1\r\nHost: \(host)\r\nAccept: */*", port: 4321, state: "good", savedClientID: saved)
        }
        func code(_ reply: LoopbackCallback.Reply) -> String? {
            if case .failure(let error)? = reply.outcome { return error.code }
            if case .success? = reply.outcome { return "success" }
            return nil
        }
        // Mismatched or unrelated requests are answered but never consume the pending sign-in.
        XCTAssertEqual(handle("/auth/callback?state=bad&code=c&client_id=client_x").status, 400)
        XCTAssertNil(handle("/auth/callback?state=bad&code=c&client_id=client_x").outcome)
        XCTAssertNil(handle("/auth/callback?state=good&state=good&code=c&client_id=client_x").outcome)
        XCTAssertEqual(handle("/other?state=good&code=c&client_id=client_x").status, 404)
        XCTAssertEqual(handle("/auth/callback?state=good&code=c&client_id=client_x", host: "localhost:4321").status, 404)
        XCTAssertEqual(code(handle("/auth/callback?state=good&error=access_denied")), "access_denied")
        XCTAssertEqual(code(handle("/auth/callback?state=good&code=c")), "registration_incomplete")
        XCTAssertEqual(code(handle("/auth/callback?state=good&code=c&client_id=dynamic_agent_client")), "registration_incomplete")
        XCTAssertEqual(code(handle("/auth/callback?state=good&code=c&client_id=client_other", saved: "client_saved")), "registration_incomplete")
        XCTAssertEqual(code(handle("/auth/callback?state=good&code=c", saved: "client_saved")), "success")
        let ok = handle("/auth/callback?state=good&code=the-code&client_id=client_x")
        guard case .success(let c, let client)? = ok.outcome else { return XCTFail("expected success") }
        XCTAssertEqual(c, "the-code"); XCTAssertEqual(client, "client_x")
        XCTAssertTrue(ok.body.contains("Oops")); XCTAssertFalse(ok.body.contains("the-code"))
    }

    func testIDTokenVerification() throws {
        let key = TestSigner.shared.publicKey, signer = TestSigner.shared
        let (subject, identity) = try ChatGPTAuth.verifyIDToken(signer.token(TestSigner.claims()), key: key, clientID: "client_test", nonce: "nonce-1", now: Date())
        XCTAssertEqual(subject, "user-1")
        XCTAssertEqual(identity, ChatGPTIdentity(email: "fake@example.invalid", name: "Test User", plan: "pro"))
        // Refresh verification has no nonce and must still accept the token.
        XCTAssertNoThrow(try ChatGPTAuth.verifyIDToken(signer.token(TestSigner.claims(nonce: nil)), key: key, clientID: "client_test", nonce: nil, now: Date()))
        var wrongIssuer = TestSigner.claims(); wrongIssuer["iss"] = "https://evil.invalid"
        var noIat = TestSigner.claims(); noIat["iat"] = nil
        var otherAzp = TestSigner.claims(); otherAzp["azp"] = "client_other"
        let rejected: [(String, String)] = [
            (TestSigner.other.token(TestSigner.claims()), "bad signature"),
            (signer.token(TestSigner.claims(client: "client_other")), "wrong audience"),
            (signer.token(TestSigner.claims(nonce: "nonce-2")), "wrong nonce"),
            (signer.token(TestSigner.claims(expires: -60)), "expired"),
            (signer.token(wrongIssuer), "wrong issuer"),
            (signer.token(noIat), "missing iat"),
            (signer.token(otherAzp), "wrong azp"),
            (signer.token(TestSigner.claims(), alg: "HS256"), "wrong algorithm"),
            ("not.a.jwt", "malformed"),
        ]
        for (token, label) in rejected {
            XCTAssertThrowsError(try ChatGPTAuth.verifyIDToken(token, key: key, clientID: "client_test", nonce: "nonce-1", now: Date()), label) {
                XCTAssertEqual(($0 as? ChatGPTError)?.code, "invalid_id_token", label)
            }
        }
        XCTAssertEqual(ChatGPTAuth.jwks(signer.jwks).count, 1)
    }

    func testTokenResponseValidation() throws {
        let now = Date()
        let (scopes, tokens) = try ChatGPTAuth.grant(["access_token": "a", "refresh_token": "r", "token_type": "bearer", "expires_in": 60,
                                                      "scope": "openid offline_access chatgpt.tokens.use.direct"], requireRefresh: false, now: now)
        XCTAssertTrue(scopes.contains("chatgpt.tokens.use.direct"))
        XCTAssertEqual(tokens.expiresAt, now.addingTimeInterval(60))
        for bad: [String: Any] in [["access_token": "a", "refresh_token": "r", "token_type": "bearer", "expires_in": 60],
                                   ["access_token": "a", "token_type": "bearer", "expires_in": 60, "scope": "offline_access"],
                                   ["access_token": "a", "refresh_token": "r", "token_type": "mac", "expires_in": 60, "scope": "openid"],
                                   ["access_token": "a", "refresh_token": "r", "token_type": "bearer", "expires_in": 0, "scope": "openid"],
                                   ["scope": "chatgpt.tokens.use.direct"]] {
            XCTAssertThrowsError(try ChatGPTAuth.grant(bad, requireRefresh: false, now: now))
        }
    }

    /// Full browser flow against a real 127.0.0.1 listener; the issuer is stubbed, the browser is this closure.
    private func signIn(store: MemoryChatGPTStore, scope: String = ChatGPTAuth.scopes, client: String = "client_test") async throws -> URL {
        let nonce = Locked<String?>(nil), opened = Locked<URL?>(nil)
        ChatGPTStub.install { request, body in
            FakeIssuer.route(request, body) { fields in
                FakeIssuer.tokens(access: "fake-access-1", refresh: "fake-refresh-1", scope: scope,
                                  idToken: TestSigner.shared.token(TestSigner.claims(client: fields["client_id"] ?? "", nonce: nonce.value)))
            } ?? StubResponse(status: 404)
        }
        let auth = ChatGPTAuth(store: store, session: ChatGPTStub.session) { url in
            opened.value = url
            let q = Dictionary((URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems ?? []).map { ($0.name, $0.value ?? "") }) { a, _ in a }
            nonce.value = q["nonce"]
            var callback = URLComponents(string: q["redirect_uri"]!)!
            callback.queryItems = [.init(name: "state", value: q["state"]), .init(name: "code", value: "fake-code"), .init(name: "client_id", value: client)]
            let target = callback.url!
            Task.detached { _ = try? await URLSession(configuration: .ephemeral).data(from: target) }
        }
        let identity = try await auth.signIn()
        XCTAssertEqual(identity, try XCTUnwrap(store.savedProfile?.identity))
        return opened.value!
    }

    func testSignInEndToEndStoresVerifiedCredentialsAndRegistration() async throws {
        let store = MemoryChatGPTStore()
        let url = try await signIn(store: store)
        XCTAssertEqual(url.host, "auth.openai.com"); XCTAssertEqual(url.path, "/oauth/authorize")
        let exchange = try XCTUnwrap(ChatGPTStub.requests(to: "/oauth/token").first)
        XCTAssertEqual(exchange.request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        let fields = form(exchange.body)
        XCTAssertEqual(fields["grant_type"], "authorization_code")
        XCTAssertEqual(fields["client_id"], "client_test")
        XCTAssertEqual(fields["code"], "fake-code")
        XCTAssertEqual(fields["resource"], "https://api.openai.com/v1")
        XCTAssertEqual(fields["redirect_uri"], query(url)["redirect_uri"])
        XCTAssertEqual(ChatGPTAuth.challenge(fields["code_verifier"]!), query(url)["code_challenge"])
        let profile = try XCTUnwrap(store.savedProfile)
        XCTAssertEqual(query(url)["ext_agent_host_id"], profile.hostID, "the host ID is chosen and saved before the first sign-in")
        XCTAssertNotNil(profile.hostID.range(of: "^urn:uuid:[0-9a-f-]{36}$", options: .regularExpression))
        XCTAssertEqual(profile.clientID, "client_test"); XCTAssertEqual(profile.subject, "user-1"); XCTAssertEqual(profile.state, .connected)
        XCTAssertEqual(store.savedCredentials?.tokens.accessToken, "fake-access-1")
        XCTAssertEqual(ChatGPTAuth(store: store, openBrowser: { _ in }).status,
                       .signedIn(ChatGPTIdentity(email: "fake@example.invalid", name: "Test User", plan: "pro")))

        // Reauthorizing reuses the issued client and the same host ID, without a name hint.
        let firstIDToken = try XCTUnwrap(store.savedCredentials?.idToken)
        let second = try await signIn(store: store)
        XCTAssertEqual(query(second)["client_id"], "client_test"); XCTAssertNil(query(second)["agent_name_hint"])
        XCTAssertEqual(query(second)["login_hint"], "fake@example.invalid")
        XCTAssertEqual(query(second)["id_token_hint"], firstIDToken, "the retained ID token identifies the account")
        XCTAssertEqual(query(second)["ext_agent_host_id"], profile.hostID)
        XCTAssertEqual(store.savedProfile?.hostID, profile.hostID)
    }

    func testSignInRequiresDirectScope() async throws {
        let store = MemoryChatGPTStore()
        do { _ = try await signIn(store: store, scope: "openid profile email offline_access"); XCTFail("must require plan usage scope") }
        catch { XCTAssertEqual((error as? ChatGPTError)?.code, "sharing_not_enabled") }
        XCTAssertNil(store.savedCredentials)
        XCTAssertEqual(store.savedProfile?.clientID, "client_test", "the issued registration is kept for the next attempt")
        XCTAssertEqual(ChatGPTAuth(store: store, openBrowser: { _ in }).status, .signedOut)

        // Continuing again asks for consent once (errors-and-recovery), then never on ordinary sign-ins.
        let retry = try await signIn(store: store)
        XCTAssertEqual(query(retry)["prompt"], "consent"); XCTAssertNil(store.savedProfile?.consentNeeded)
        let ordinary = try await signIn(store: store)
        XCTAssertNil(query(ordinary)["prompt"])
    }

    func testProactiveRefreshNearExpiryVerifiesRotatedIdentity() async throws {
        let store = MemoryChatGPTStore(profile: .fakeConnected, credentials: .fake(expiresIn: 30))
        ChatGPTStub.install { request, body in
            FakeIssuer.route(request, body) { _ in
                FakeIssuer.tokens(access: "fake-access-2", scope: nil, idToken: TestSigner.shared.token(TestSigner.claims(nonce: nil)))
            } ?? StubResponse(status: 404)
        }
        let auth = ChatGPTAuth(store: store, session: ChatGPTStub.session, openBrowser: { _ in })
        async let a = auth.validAccessToken(); async let b = auth.validAccessToken()
        let tokens = try await [a, b]
        XCTAssertEqual(tokens, ["fake-access-2", "fake-access-2"])
        let refreshes = ChatGPTStub.requests(to: "/oauth/token")
        XCTAssertEqual(refreshes.count, 1, "concurrent callers share one refresh")
        XCTAssertEqual(form(refreshes[0].body), ["grant_type": "refresh_token", "client_id": "client_test",
                                                 "refresh_token": "fake-refresh-1", "resource": "https://api.openai.com/v1"])
        XCTAssertEqual(store.savedCredentials?.tokens.refreshToken, "fake-refresh-2")
        XCTAssertNil(store.savedCredentials?.pending)
        XCTAssertTrue(store.savedCredentials?.scopes.contains("chatgpt.tokens.use.direct") == true, "omitted scope keeps the granted scopes")
        let fresh = try await auth.validAccessToken()
        XCTAssertEqual(fresh, "fake-access-2"); XCTAssertEqual(ChatGPTStub.requests(to: "/oauth/token").count, 1)
    }

    func testRefreshRejectionRequiresReauthentication() async throws {
        let store = MemoryChatGPTStore(profile: .fakeConnected, credentials: .fake(expiresIn: -10))
        ChatGPTStub.install { request, body in
            FakeIssuer.route(request, body) { _ in StubResponse(status: 400, body: json(["error": "invalid_grant", "error_description": "echo fake-refresh-1"])) } ?? StubResponse(status: 404)
        }
        let auth = ChatGPTAuth(store: store, session: ChatGPTStub.session, openBrowser: { _ in })
        do { _ = try await auth.validAccessToken(); XCTFail("must fail") }
        catch { XCTAssertEqual((error as? ChatGPTError)?.code, "invalid_grant"); XCTAssertFalse(error.localizedDescription.contains("fake-refresh")) }
        XCTAssertEqual(auth.status, .reauthRequired)
        XCTAssertNil(store.savedCredentials)
        XCTAssertEqual(store.savedProfile?.clientID, "client_test")
    }

    func testIdentityOutageKeepsPendingRotationForLaterVerification() async throws {
        let store = MemoryChatGPTStore(profile: .fakeConnected, credentials: .fake(expiresIn: 10))
        let jwksUp = Locked(false)
        ChatGPTStub.install { request, body in
            if request.url?.path == "/.well-known/jwks.json", !jwksUp.value { return StubResponse(status: 503) }
            return FakeIssuer.route(request, body) { _ in
                FakeIssuer.tokens(access: "fake-access-2", idToken: TestSigner.shared.token(TestSigner.claims(nonce: nil)))
            } ?? StubResponse(status: 404)
        }
        let auth = ChatGPTAuth(store: store, session: ChatGPTStub.session, openBrowser: { _ in })
        do { _ = try await auth.validAccessToken(); XCTFail("must wait for verification") }
        catch { XCTAssertEqual((error as? ChatGPTError)?.code, "identity_verification_unavailable") }
        XCTAssertEqual(store.savedCredentials?.pending?.tokens.accessToken, "fake-access-2")
        XCTAssertEqual(store.savedCredentials?.tokens.accessToken, "fake-access-1", "unverified credentials are never used")
        jwksUp.value = true
        let token = try await auth.validAccessToken()
        XCTAssertEqual(token, "fake-access-2")
        XCTAssertEqual(ChatGPTStub.requests(to: "/oauth/token").count, 1, "the consumed refresh token is not replayed")
    }

    func testSignOutRevokesAndKeepsRegistrationUnlessForgotten() async throws {
        let store = MemoryChatGPTStore(profile: .fakeConnected, credentials: .fake())
        ChatGPTStub.install { request, body in FakeIssuer.route(request, body) ?? StubResponse(status: 404) }
        let auth = ChatGPTAuth(store: store, session: ChatGPTStub.session, openBrowser: { _ in })
        try await auth.signOut()
        XCTAssertEqual(auth.status, .signedOut)
        XCTAssertNil(store.savedCredentials)
        XCTAssertEqual(store.savedProfile?.clientID, "client_test"); XCTAssertEqual(store.savedProfile?.subject, "user-1")
        let revoke = try XCTUnwrap(ChatGPTStub.requests(to: "/oauth/revoke").first)
        XCTAssertEqual(form(revoke.body), ["token": "fake-refresh-1", "token_type_hint": "refresh_token", "client_id": "client_test"])
        do { _ = try await auth.validAccessToken(); XCTFail("signed out") } catch { XCTAssertEqual((error as? ChatGPTError)?.code, "sign_in_required") }

        try await auth.signOut(forgetAccount: true)
        XCTAssertNil(store.savedProfile?.clientID); XCTAssertNil(store.savedProfile?.subject)
        XCTAssertEqual(store.savedProfile?.hostID, ChatGPTProfile.fakeConnected.hostID, "the host ID survives forgetting the account")
    }
}

final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock(); private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { get { lock.withLock { stored } } set { lock.withLock { stored = newValue } } }
}
