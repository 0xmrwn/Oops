import XCTest
@testable import OopsCore

final class ChatGPTCancellationTests: XCTestCase {
    func testCancellationDuringRefreshDoesNotSubmitCorrection() async throws {
        try await checkCancellation(rejected: false)
    }

    func testCancellationDuringUnauthorizedRefreshDoesNotRetryCorrection() async throws {
        try await checkCancellation(rejected: true)
    }

    func testDeadlineDuringRefreshDoesNotSubmitCorrection() async throws {
        try await checkCancellation(rejected: false, deadline: true)
    }

    func testCancellationDuringUnauthorizedRefreshDoesNotRunBodyAgain() async throws {
        let refreshStarted = expectation(description: "refresh sent")
        let releaseRefresh = DispatchSemaphore(value: 0)
        defer { releaseRefresh.signal() }
        let store = MemoryChatGPTStore(profile: .fakeConnected, credentials: .fake())
        ChatGPTStub.install { request, body in
            FakeIssuer.route(request, body) { _ in
                refreshStarted.fulfill()
                XCTAssertEqual(releaseRefresh.wait(timeout: .now() + 5), .success)
                return FakeIssuer.tokens(access: "fake-access-2")
            } ?? StubResponse(status: 500)
        }
        let auth = ChatGPTAuth(store: store, session: ChatGPTStub.session, openBrowser: { _ in })
        let calls = Locked(0)
        let caller = Task {
            try await auth.withAccessToken { _ in
                calls.value += 1
                if calls.value == 1 { throw ChatGPTError.named("unauthorized", status: 401) }
                return "late"
            }
        }
        await fulfillment(of: [refreshStarted], timeout: 5)
        caller.cancel()
        releaseRefresh.signal()
        do { _ = try await caller.value; XCTFail("must cancel") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(calls.value, 1, "cancellation must stop the authenticated body even if its transport ignores cancellation")
        XCTAssertEqual(store.savedCredentials?.tokens.refreshToken, "fake-refresh-2")
    }

    private struct FixtureTimeout: Error {}

    private func checkCancellation(rejected: Bool, deadline: Bool = false) async throws {
        let refreshStarted = expectation(description: "refresh sent")
        let deadlineReached = deadline ? expectation(description: "deadline cancelled the correction") : nil
        let releaseRefresh = DispatchSemaphore(value: 0)
        defer { releaseRefresh.signal() }
        let store = MemoryChatGPTStore(profile: .fakeConnected, credentials: .fake(expiresIn: rejected ? 3600 : -1))
        let calls = Locked(0)
        ChatGPTStub.install { request, body in
            if let response = FakeIssuer.route(request, body, token: { _ in
                refreshStarted.fulfill()
                XCTAssertEqual(releaseRefresh.wait(timeout: .now() + 5), .success)
                return FakeIssuer.tokens(access: "fake-access-2")
            }) { return response }
            calls.value += 1
            if rejected, calls.value == 1 { return StubResponse(status: 401) }
            let events: [[String: Any]] = [
                ["type": "response.output_text.delta", "delta": #"{"text":"This is a test."}"#],
                ["type": "response.completed", "response": ["status": "completed"]]
            ]
            let stream = events.map { "data: \(String(decoding: json($0), as: UTF8.self))\n\n" }.joined()
            return StubResponse(headers: ["Content-Type": "text/event-stream"], body: Data(stream.utf8))
        }
        let auth = ChatGPTAuth(store: store, session: ChatGPTStub.session, openBrowser: { _ in })
        let backend = ChatGPTBackend(auth: auth, model: "gpt-6-luna")
        let caller = Task {
            if deadline {
                return try await withDeadline(.seconds(1), orThrow: FixtureTimeout()) {
                    try await withTaskCancellationHandler {
                        try await backend.complete("ths is a test.", instructions: CorrectionPolicy.instructions)
                    } onCancel: { deadlineReached?.fulfill() }
                }
            }
            return try await backend.complete("ths is a test.", instructions: CorrectionPolicy.instructions)
        }
        await fulfillment(of: [refreshStarted], timeout: 5)
        if let deadlineReached { await fulfillment(of: [deadlineReached], timeout: 5) }
        else { caller.cancel() }
        releaseRefresh.signal()
        do { _ = try await caller.value; XCTFail("must cancel") }
        catch { XCTAssertTrue(deadline ? error is FixtureTimeout : error is CancellationError, "\(error)") }
        XCTAssertEqual(store.savedCredentials?.tokens.refreshToken, "fake-refresh-2")
        XCTAssertEqual(ChatGPTStub.requests(to: "/oauth/token").count, 1)
        XCTAssertEqual(ChatGPTStub.requests(to: "/v1/responses").count, rejected ? 1 : 0,
                       "cancellation must not send the draft after refresh")
        let corrected = try await backend.correct("ths is a test.")
        XCTAssertEqual(corrected, "This is a test.", "the saved rotation must remain usable by the next correction")
        XCTAssertEqual(ChatGPTStub.requests(to: "/oauth/token").count, 1)
    }
}
