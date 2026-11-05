import XCTest
@testable import OopsCore

/// Session upkeep after sign-in: refresh outcomes, sign-out, error codes and the stored shape.
final class ChatGPTSessionTests: XCTestCase {
    private func auth(_ store: MemoryChatGPTStore, token: @escaping ([String: String]) -> StubResponse,
                      revoke: StubResponse = StubResponse(body: Data())) -> ChatGPTAuth {
        ChatGPTStub.install { request, body in
            if request.url?.path == "/oauth/revoke" { return revoke }
            return FakeIssuer.route(request, body, token: token) ?? StubResponse(status: 404)
        }
        return ChatGPTAuth(store: store, session: ChatGPTStub.session, openBrowser: { _ in })
    }

    func testRefreshWithoutRotationKeepsTheRefreshToken() async throws {
        let store = MemoryChatGPTStore(profile: .fakeConnected, credentials: .fake(expiresIn: 20))
        let auth = auth(store) { _ in
            StubResponse(body: json(["access_token": "fake-access-2", "token_type": "Bearer", "expires_in": 3600]))
        }
        let token = try await auth.validAccessToken()
        XCTAssertEqual(token, "fake-access-2")
        XCTAssertEqual(store.savedCredentials?.tokens.refreshToken, "fake-refresh-1", "RFC 6749 §6: no replacement, the old one stays")
        XCTAssertEqual(store.savedCredentials?.idToken, "fake.id.token")
    }

    func testEarliestRefreshAtDefersProactiveRefresh() async throws {
        var credentials = ChatGPTCredentials.fake(expiresIn: 60)
        credentials.tokens.earliestRefreshAt = Date().addingTimeInterval(30)
        let store = MemoryChatGPTStore(profile: .fakeConnected, credentials: credentials)
        let auth = auth(store) { _ in StubResponse(status: 500) }
        let token = try await auth.validAccessToken()
        XCTAssertEqual(token, "fake-access-1")
        XCTAssertTrue(ChatGPTStub.requests(to: "/oauth/token").isEmpty)
    }

    func testNoRefreshBeforeTheServersBoundaryEvenWhenExpired() async throws {
        var credentials = ChatGPTCredentials.fake(expiresIn: -5)
        credentials.tokens.earliestRefreshAt = Date().addingTimeInterval(30)
        let store = MemoryChatGPTStore(profile: .fakeConnected, credentials: credentials)
        let auth = auth(store) { _ in FakeIssuer.tokens(access: "fake-access-2") }
        do { _ = try await auth.validAccessToken(); XCTFail("must wait") } catch {
            XCTAssertEqual((error as? ChatGPTError)?.code, "refresh_deferred"); XCTAssertTrue((error as? ChatGPTError)?.retryable == true)
        }
        XCTAssertTrue(ChatGPTStub.requests(to: "/oauth/token").isEmpty)
        XCTAssertNotNil(store.savedCredentials)
    }

    /// The server spends the old refresh token as soon as it answers, so a cancelled caller must not lose the answer.
    func testCancelledCallerStillSavesTheRotatedTokens() async throws {
        let store = MemoryChatGPTStore(profile: .fakeConnected, credentials: .fake(expiresIn: -1))
        let auth = auth(store) { _ in
            Thread.sleep(forTimeInterval: 0.3)
            return StubResponse(body: json(["access_token": "fake-access-2", "refresh_token": "fake-refresh-2", "token_type": "Bearer", "expires_in": 3600]))
        }
        let caller = Task { try await auth.validAccessToken() }
        try await Task.sleep(for: .milliseconds(100))
        caller.cancel()
        _ = try? await caller.value
        XCTAssertEqual(store.savedCredentials?.tokens.refreshToken, "fake-refresh-2")
        XCTAssertEqual(ChatGPTStub.requests(to: "/oauth/token").count, 1)
    }

    /// Signing out while a finished browser sign-in is still being verified: the sign-out wins.
    func testSignOutDuringVerificationDiscardsTheSignIn() async throws {
        let store = MemoryChatGPTStore(), holder = Locked<ChatGPTAuth?>(nil), nonce = Locked<String?>(nil)
        ChatGPTStub.install { request, body in
            if request.url?.path == "/.well-known/jwks.json" { holder.value?.cancelSignIn() }
            return FakeIssuer.route(request, body) { fields in
                FakeIssuer.tokens(access: "fake-access-1", idToken: TestSigner.shared.token(TestSigner.claims(client: fields["client_id"] ?? "", nonce: nonce.value)))
            } ?? StubResponse(status: 404)
        }
        let auth = ChatGPTAuth(store: store, session: ChatGPTStub.session) { url in
            let q = Dictionary((URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems ?? []).map { ($0.name, $0.value ?? "") }) { a, _ in a }
            nonce.value = q["nonce"]
            var callback = URLComponents(string: q["redirect_uri"]!)!
            callback.queryItems = [.init(name: "state", value: q["state"]), .init(name: "code", value: "fake-code"), .init(name: "client_id", value: "client_test")]
            let target = callback.url!
            Task.detached { _ = try? await URLSession(configuration: .ephemeral).data(from: target) }
        }
        holder.value = auth
        do { try await auth.signIn(); XCTFail("superseded") } catch { XCTAssertEqual((error as? ChatGPTError)?.code, "cancelled") }
        XCTAssertNil(store.savedCredentials)
        XCTAssertEqual(auth.status, .signedOut)
    }

    func testRefreshThatLosesPlanScopeEndsTheSessionAndAsksForConsent() async throws {
        let store = MemoryChatGPTStore(profile: .fakeConnected, credentials: .fake(expiresIn: -1))
        let auth = auth(store) { _ in FakeIssuer.tokens(access: "fake-access-2", scope: "openid email offline_access") }
        do { _ = try await auth.validAccessToken(); XCTFail("must stop") } catch { XCTAssertEqual((error as? ChatGPTError)?.code, "sharing_not_enabled") }
        XCTAssertNil(store.savedCredentials)
        XCTAssertEqual(store.savedProfile?.consentNeeded, true)
        XCTAssertEqual(auth.status, .reauthRequired)
    }

    func testInvalidClientDropsTheRegistrationButKeepsTheHost() async throws {
        let store = MemoryChatGPTStore(profile: .fakeConnected, credentials: .fake(expiresIn: -1))
        let auth = auth(store) { _ in StubResponse(status: 401, body: json(["error": "invalid_client"])) }
        do { _ = try await auth.validAccessToken(); XCTFail("must stop") } catch { XCTAssertEqual((error as? ChatGPTError)?.code, "invalid_client") }
        XCTAssertNil(store.savedCredentials); XCTAssertNil(store.savedProfile?.clientID)
        XCTAssertEqual(store.savedProfile?.hostID, ChatGPTProfile.fakeConnected.hostID)
        XCTAssertEqual(auth.status, .reauthRequired)
    }

    func testTemporaryRefreshFailuresKeepCredentials() async throws {
        let store = MemoryChatGPTStore(profile: .fakeConnected, credentials: .fake(expiresIn: -1))
        let auth = auth(store) { _ in StubResponse(status: 503, body: Data("echo fake-refresh-1".utf8)) }
        do { _ = try await auth.validAccessToken(); XCTFail("must fail") } catch {
            XCTAssertTrue((error as? ChatGPTError)?.retryable == true); XCTAssertFalse(error.localizedDescription.contains("fake-refresh"))
        }
        XCTAssertNotNil(store.savedCredentials, "an outage is not a revocation")
        XCTAssertEqual(auth.status, .signedIn(ChatGPTIdentity(email: "fake@example.invalid")))
    }

    func testUnconfirmedRevocationRetriesThenSignsOutLocallyAndSaysSo() async throws {
        let store = MemoryChatGPTStore(profile: .fakeConnected, credentials: .fake())
        let auth = auth(store, token: { _ in StubResponse(status: 500) }, revoke: StubResponse(status: 503))
        do { try await auth.signOut(); XCTFail("must report it") } catch { XCTAssertEqual((error as? ChatGPTError)?.code, "revocation_unconfirmed") }
        XCTAssertEqual(ChatGPTStub.requests(to: "/oauth/revoke").count, 3)
        XCTAssertNil(store.savedCredentials)
        XCTAssertEqual(auth.status, .signedOut)
    }

    func testAPIErrorsReadMachineCodesNeverServerText() {
        let admission = ChatGPTError.api(["detail": "echo secret"], status: 503)
        XCTAssertEqual(admission.code, "service_unavailable"); XCTAssertTrue(admission.retryable); XCTAssertEqual(admission.status, 503)
        let structured = ChatGPTError.api(["error": ["code": "subscription_sharing_user_unavailable", "message": "echo secret"]], status: 503)
        XCTAssertEqual(structured.code, "subscription_sharing_user_unavailable"); XCTAssertTrue(structured.retryable)
        XCTAssertFalse(structured.message.contains("secret"))
        XCTAssertEqual(ChatGPTError.api(["type": "error", "code": "rate_limit_exceeded"], status: nil).code, "rate_limit_exceeded")
        XCTAssertEqual(ChatGPTError.api(["error": "invalid_grant"], status: 400).code, "invalid_grant")
        XCTAssertEqual(ChatGPTError.api(nil, status: 401).code, "unauthorized")
        XCTAssertEqual(ChatGPTError.api(nil, status: 418).code, "request_failed")
        let unlisted = ChatGPTError.api(["error": ["code": "insufficient_quota"]], status: 429)
        XCTAssertEqual(unlisted.code, "insufficient_quota", "an unlisted code is kept"); XCTAssertEqual(unlisted.status, 429)
    }

    /// Records written before the rewrite: dates as JSONEncoder's default (seconds since 2001), no `consentNeeded`.
    func testRecordsSavedBeforeTheRewriteStillRead() throws {
        let profile = #"{"version":1,"hostID":"urn:uuid:00000000-0000-4000-8000-000000000000","clientID":"client_test","subject":"user-1","identity":{"email":"fake@example.invalid","name":"Test User"},"state":"connected"}"#
        XCTAssertEqual(try JSONDecoder().decode(ChatGPTProfile.self, from: Data(profile.utf8)).identity?.name, "Test User")
        let credentials = #"{"clientID":"client_test","scopes":["openid","chatgpt.tokens.use.direct"],"idToken":"fake.id.token","tokens":{"accessToken":"fake-access-1","refreshToken":"fake-refresh-1","expiresAt":815000000}}"#
        let decoded = try JSONDecoder().decode(ChatGPTCredentials.self, from: Data(credentials.utf8))
        XCTAssertEqual(decoded.tokens.expiresAt, Date(timeIntervalSinceReferenceDate: 815_000_000)); XCTAssertNil(decoded.pending)
    }
}
