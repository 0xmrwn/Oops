import Combine
import Foundation
@testable import Oops
import OopsCore
import Synchronization
import Testing
import XCTest

@MainActor struct ChatGPTStatusTests {
    @Test func `startup and the main actor stay responsive while account status waits`() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let preferences = fixture.preferences()
        #expect(preferences.chatGPTStatus == nil)
        #expect(preferences.providers.selection.choice == fixture.choice)
        try #require(fixture.store.reads == 0)

        preferences.refreshChatGPT()
        try await wait(for: fixture.store.readStarted)
        for _ in 0..<10 { preferences.refreshChatGPT(loadCatalog: true) }
        MainActor.preconditionIsolated()
        #expect(fixture.store.heldReadOnMainThread == false)
        #expect(!fixture.store.heldReadFinished)
        #expect(preferences.chatGPTStatus == nil)
        #expect(!preferences.modelsLoading)

        let loaded = XCTestExpectation(description: "Catalog published")
        let observer = preferences.$models.first { $0.first?.slug == "synthetic-chat" }.sink { _ in loaded.fulfill() }
        defer { observer.cancel() }
        fixture.store.releaseRead()
        try await wait(for: loaded)
        #expect(preferences.chatGPTStatus == .signedIn(fixture.store.identity))
        #expect(preferences.providers.selection.choice == fixture.choice)
        #expect(fixture.store.reads == 2, "One status read and one catalog token read")
    }

    @Test func `sign out rejects a blocked read of the old connected account`() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let preferences = fixture.preferences()
        var published: [ChatGPTStatus] = []
        let observer = preferences.$chatGPTStatus.compactMap(\.self).sink { published.append($0) }
        defer { observer.cancel() }
        preferences.refreshChatGPT()
        try await wait(for: fixture.store.readStarted)
        let disconnected = XCTestExpectation(description: "Sign out completed")
        let disconnectObserver = preferences.$disconnecting.dropFirst().first { !$0 }.sink { _ in disconnected.fulfill() }
        defer { disconnectObserver.cancel() }
        preferences.signOut()
        try await wait(for: disconnected)
        #expect(fixture.store.reads == 2)
        #expect(preferences.chatGPTStatus == .signedOut)
        fixture.store.releaseRead()
        try await wait(for: fixture.store.thirdProfileRead)
        #expect(published == [.signedOut])
        #expect(fixture.store.reads == 2)
        #expect(preferences.providers.selection.choice == fixture.choice)
    }

    @Test func `cancelled sign in ignores an earlier connected status`() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let preferences = fixture.preferences()
        var published: [ChatGPTStatus] = [], signIns = 0
        let signedOut = XCTestExpectation(description: "Current account published")
        let statusObserver = preferences.$chatGPTStatus.compactMap(\.self).sink {
            published.append($0)
            if $0 == .signedOut { signedOut.fulfill() }
        }
        let signInObserver = preferences.chatGPTSignInCompleted.sink { signIns += 1 }
        defer { statusObserver.cancel(); signInObserver.cancel() }
        preferences.refreshChatGPT()
        try await wait(for: fixture.store.readStarted)
        preferences.signInWithChatGPT()
        try fixture.store.writeProfile(ChatGPTProfile(hostID: "fixture"))
        preferences.cancelSignIn()
        fixture.store.releaseRead()
        try await wait(for: signedOut)
        #expect(published == [.signedOut])
        #expect(signIns == 0)
        #expect(!preferences.signingIn)
        #expect(fixture.store.reads == 1)
    }

    @Test func `sign out prevents a pending catalog from publishing`() async throws {
        let fixture = try Fixture(holdCredentialRead: 2)
        defer { fixture.cleanUp() }
        let preferences = fixture.preferences()
        preferences.refreshChatGPT(loadCatalog: true)
        try await wait(for: fixture.store.readStarted)
        #expect(preferences.modelsLoading)
        let catalog = try #require(preferences.modelsTask)
        let signedOut = XCTestExpectation(description: "Signed out after catalog cancellation")
        let observer = preferences.$chatGPTStatus.first { $0 == .signedOut }.sink { _ in signedOut.fulfill() }
        defer { observer.cancel() }
        preferences.signOut()
        #expect(!preferences.modelsLoading)
        fixture.store.releaseRead()
        let catalogFinished = XCTestExpectation(description: "Cancelled catalog finished")
        Task { await catalog.value; catalogFinished.fulfill() }
        try await wait(for: catalogFinished)
        try await wait(for: signedOut)
        #expect(!preferences.disconnecting)
        #expect(preferences.models.isEmpty)
        #expect(preferences.modelsError == nil)
    }

    @Test func `a blocked read does not own Preferences`() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        var preferences: Preferences? = fixture.preferences()
        weak let owner = preferences
        preferences?.refreshChatGPT()
        try await wait(for: fixture.store.readStarted)
        preferences = nil
        #expect(owner == nil)
        #expect(!fixture.store.heldReadFinished)
        fixture.store.releaseRead()
        try await wait(for: fixture.store.readFinished)
    }

    @Test func `onboarding discovers an existing account without a sign in event`() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let preferences = fixture.preferences()
        let detected = XCTestExpectation(description: "Existing account detected")
        var detections = 0
        let step = ProviderStep(preferences: preferences, detection: {
            detections += 1
            detected.fulfill()
            #expect(preferences.chatGPTStatus == .signedIn(fixture.store.identity))
            return ProviderFindings()
        })
        defer { step.stop() }
        step.start()
        try await wait(for: fixture.store.readStarted)
        #expect(detections == 0)
        fixture.store.releaseRead()
        try await wait(for: detected)
        #expect(detections == 1)
        #expect(step.selected == nil)
        #expect(step.proof == .idle)
        preferences.chatGPTSignInCompleted.send(())
        #expect(step.selected == .chatGPT)
    }

    private func wait(for event: XCTestExpectation) async throws {
        let result = await XCTWaiter.fulfillment(of: [event], timeout: 30)
        try #require(result == .completed, "Timed out waiting for \(event.expectationDescription)")
    }

    @MainActor private struct Fixture {
        let store: BlockingStore
        let choice = ModelSelection.Choice(providerID: "synthetic-local", modelID: "local-model")
        let defaults: UserDefaults
        let suite = "oops-status-test-" + UUID().uuidString

        init(holdCredentialRead: Int = 1) throws {
            store = BlockingStore(holdCredentialRead: holdCredentialRead)
            defaults = try #require(UserDefaults(suiteName: suite))
            let local = Provider(id: choice.providerID, kind: .api(preset: nil), name: "Local fixture",
                                 baseURL: "http://127.0.0.1:1/v1", shownModels: [choice.modelID])
            defaults.set(try JSONEncoder().encode([Provider.chatGPT(), local]), forKey: "providers")
            defaults.set(try JSONEncoder().encode(ModelSelection(choice: choice)), forKey: "modelSelection")
        }

        func preferences() -> Preferences {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [CatalogStub.self]
            let auth = ChatGPTAuth(store: store, session: URLSession(configuration: configuration), openBrowser: { _ in
                Issue.record("Status and catalog should not open a browser")
            })
            return Preferences(auth: auth, defaults: defaults)
        }

        func cleanUp() {
            store.releaseRead()
            defaults.removePersistentDomain(forName: suite)
        }
    }
}

private final class BlockingStore: ChatGPTStore, Sendable {
    private struct State {
        var profile: ChatGPTProfile
        var credentials: ChatGPTCredentials?
        var reads = 0
        var profileReads = 0
        var heldReadOnMainThread: Bool?
        var heldReadFinished = false
    }

    let identity = ChatGPTIdentity(name: "Synthetic Account")
    private let holdCredentialRead: Int
    private let state: Mutex<State>
    let readStarted = XCTestExpectation(description: "Credential read entered")
    let readFinished = XCTestExpectation(description: "Credential read finished")
    let thirdProfileRead = XCTestExpectation(description: "Account rechecked after sign out")
    private let release = DispatchSemaphore(value: 0)

    init(holdCredentialRead: Int) {
        self.holdCredentialRead = holdCredentialRead
        let profile = ChatGPTProfile(hostID: "fixture", identity: identity, state: .connected)
        let tokens = ChatGPTTokens(accessToken: "synthetic", refreshToken: nil,
                                   expiresAt: .now.addingTimeInterval(3600), earliestRefreshAt: nil)
        state = Mutex(State(profile: profile, credentials: ChatGPTCredentials(clientID: "fixture", scopes: [], idToken: "", tokens: tokens)))
    }

    var reads: Int { state.withLock { $0.reads } }
    var heldReadOnMainThread: Bool? { state.withLock { $0.heldReadOnMainThread } }
    var heldReadFinished: Bool { state.withLock { $0.heldReadFinished } }
    func releaseRead() { release.signal() }
    func readProfile() throws -> ChatGPTProfile? {
        state.withLock {
            $0.profileReads += 1
            if $0.profileReads == 3 { thirdProfileRead.fulfill() }
            return $0.profile
        }
    }
    func writeProfile(_ profile: ChatGPTProfile) throws { state.withLock { $0.profile = profile } }
    func writeCredentials(_ credentials: ChatGPTCredentials) throws { state.withLock { $0.credentials = credentials } }
    func deleteCredentials() throws { state.withLock { $0.credentials = nil } }

    func readCredentials() throws -> ChatGPTCredentials? {
        let (held, snapshot) = state.withLock {
            $0.reads += 1
            let held = $0.reads == holdCredentialRead
            if held { $0.heldReadOnMainThread = Thread.isMainThread }
            return (held, $0.credentials)
        }
        if held {
            readStarted.fulfill()
            if Thread.isMainThread {
                Issue.record("Credential read would block the main thread")
            } else {
                release.wait()
            }
            state.withLock { $0.heldReadFinished = true }
            readFinished.fulfill()
        }
        return snapshot
    }
}

private final class CatalogStub: URLProtocol, @unchecked Sendable {
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, url.path == "/v1/models",
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"models":[{"slug":"synthetic-chat","display_name":"Synthetic","visibility":"list"}]}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
