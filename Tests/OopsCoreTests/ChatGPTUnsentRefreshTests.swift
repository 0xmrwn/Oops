import XCTest
@testable import OopsCore

final class ChatGPTUnsentRefreshTests: XCTestCase {
    func testPreparationCancelledAtEntryDoesNotReachStore() async {
        let entered = Locked(false)
        let store = MemoryChatGPTStore(profile: .fakeConnected, credentials: .fake(expiresIn: -1)) { entered.value = true }
        ChatGPTStub.install { _, _ in StubResponse(status: 500) }
        let backend = backend(store)
        let preparation = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await backend.prepare()
        }
        await preparation.value
        XCTAssertFalse(entered.value)
        XCTAssertEqual(store.credentialReads, 0)
        XCTAssertTrue(ChatGPTStub.requests.isEmpty)
    }

    func testCancelledPreparationDoesNotRefreshAfterStoreWait() async {
        let waiting = expectation(description: "preparation reached store lock")
        let (release, continuation) = AsyncStream<Void>.makeStream()
        defer { continuation.finish() }
        let store = MemoryChatGPTStore(profile: .fakeConnected, credentials: .fake(expiresIn: -1)) {
            waiting.fulfill()
            for await _ in release { break }
        }
        ChatGPTStub.install { request, body in
            FakeIssuer.route(request, body) { _ in FakeIssuer.tokens(access: "fake-access-2") } ?? StubResponse(status: 404)
        }
        let backend = backend(store)
        let preparation = Task { await backend.prepare() }
        await fulfillment(of: [waiting], timeout: 5)
        preparation.cancel()
        continuation.finish()
        await preparation.value
        XCTAssertEqual(store.credentialReads, 0)
        XCTAssertTrue(ChatGPTStub.requests.isEmpty, "an obsolete waiter must not contact the auth service")
        XCTAssertEqual(store.savedCredentials?.tokens.refreshToken, "fake-refresh-1")
    }

    #if DEBUG
    private struct QueueWaitTimeout: Error {}

    func testCancelledGateWaiterSkipsStoreAndLetsTheNextCallerRefresh() async throws {
        let firstEnteredStore = expectation(description: "first caller holds the gate")
        let (release, continuation) = AsyncStream<Void>.makeStream()
        defer { continuation.finish() }
        let storeEntries = Locked(0), refreshes = Locked(0)
        let store = MemoryChatGPTStore(profile: .fakeConnected, credentials: .fake(expiresIn: -1)) {
            storeEntries.value += 1
            if storeEntries.value == 1 {
                firstEnteredStore.fulfill()
                for await _ in release { break }
            }
        }
        ChatGPTStub.install { request, body in
            FakeIssuer.route(request, body) { _ in
                refreshes.value += 1
                return refreshes.value == 1 ? StubResponse(status: 503) : FakeIssuer.tokens(access: "fake-access-2")
            } ?? StubResponse(status: 404)
        }
        let backend = backend(store)
        let first = Task { await backend.prepare() }
        await fulfillment(of: [firstEnteredStore], timeout: 5)
        let waiter = Task { await backend.prepare() }
        defer { waiter.cancel() }
        try await withDeadline(.seconds(5), orThrow: QueueWaitTimeout()) {
            while await backend.auth.queuedRefreshes() == 0 {
                try Task.checkCancellation()
                await Task.yield()
            }
        }
        waiter.cancel()
        continuation.finish()
        await first.value
        await waiter.value
        XCTAssertEqual(storeEntries.value, 1, "a cancelled gate waiter must not enter the store")
        XCTAssertEqual(store.credentialReads, 1)
        XCTAssertEqual(refreshes.value, 1, "the cancelled waiter must not retry the failed refresh")
        XCTAssertEqual(store.savedCredentials?.tokens.refreshToken, "fake-refresh-1")

        let token = try await backend.auth.validAccessToken()
        XCTAssertEqual(token, "fake-access-2")
        XCTAssertEqual(storeEntries.value, 2)
        XCTAssertEqual(refreshes.value, 2)
        XCTAssertEqual(store.savedCredentials?.tokens.refreshToken, "fake-refresh-2")
    }
    #endif

    func testCancelledPreparationDoesNotRefreshAfterDiscovery() async {
        let discoveryStarted = expectation(description: "discovery requested")
        let releaseDiscovery = DispatchSemaphore(value: 0)
        defer { releaseDiscovery.signal() }
        let store = MemoryChatGPTStore(profile: .fakeConnected, credentials: .fake(expiresIn: -1))
        ChatGPTStub.install { request, body in
            if request.url?.path == "/.well-known/openid-configuration" {
                discoveryStarted.fulfill()
                XCTAssertEqual(releaseDiscovery.wait(timeout: .now() + 5), .success)
            }
            return FakeIssuer.route(request, body) { _ in FakeIssuer.tokens(access: "fake-access-2") } ?? StubResponse(status: 404)
        }
        let backend = backend(store)
        let preparation = Task { await backend.prepare() }
        await fulfillment(of: [discoveryStarted], timeout: 5)
        preparation.cancel()
        releaseDiscovery.signal()
        await preparation.value
        XCTAssertTrue(ChatGPTStub.requests(to: "/oauth/token").isEmpty, "discovery must not lead to a refresh for a cancelled caller")
        XCTAssertEqual(store.savedCredentials?.tokens.refreshToken, "fake-refresh-1")
    }

    func testCancelledPreparationLetsSentRotationFinishVerification() async {
        let verificationStarted = expectation(description: "verifying the saved pending rotation")
        let releaseVerification = DispatchSemaphore(value: 0)
        defer { releaseVerification.signal() }
        let store = MemoryChatGPTStore(profile: .fakeConnected, credentials: .fake(expiresIn: -1))
        ChatGPTStub.install { request, body in
            if request.url?.path == "/.well-known/jwks.json" {
                verificationStarted.fulfill()
                XCTAssertEqual(releaseVerification.wait(timeout: .now() + 5), .success)
            }
            return FakeIssuer.route(request, body) { _ in
                FakeIssuer.tokens(access: "fake-access-2", idToken: TestSigner.shared.token(TestSigner.claims(nonce: nil)))
            } ?? StubResponse(status: 404)
        }
        let backend = backend(store)
        let preparation = Task { await backend.prepare() }
        await fulfillment(of: [verificationStarted], timeout: 5)
        XCTAssertEqual(store.savedCredentials?.pending?.tokens.refreshToken, "fake-refresh-2")
        preparation.cancel()
        releaseVerification.signal()
        await preparation.value
        XCTAssertEqual(ChatGPTStub.requests(to: "/oauth/token").count, 1)
        XCTAssertNil(store.savedCredentials?.pending)
        XCTAssertEqual(store.savedCredentials?.tokens.refreshToken, "fake-refresh-2")
    }

    private func backend(_ store: MemoryChatGPTStore) -> ChatGPTBackend {
        let auth = ChatGPTAuth(store: store, session: ChatGPTStub.session, openBrowser: { _ in })
        return ChatGPTBackend(auth: auth, model: "gpt-6-luna")
    }
}
