import XCTest
@testable import OopsCore

final class ChatGPTModelsTests: XCTestCase {
    func testCatalogDecodingFiltersHiddenAndKeepsEffortsAndFastTier() throws {
        let models = try ChatGPTModels.decode(Data(chatGPTModelsFixture.utf8))
        XCTAssertEqual(models.map(\.slug), ["gpt-6.1-sol", "gpt-6-astra", "gpt-6-sol", "gpt-6-luna", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna"])
        XCTAssertTrue(models.allSatisfy(\.visible))
        let all = try ChatGPTModels.decode(Data(chatGPTModelsFixture.utf8), includeHidden: true)
        XCTAssertEqual(all.count, 9)
        XCTAssertEqual(all.filter { !$0.visible }.map(\.slug).sorted(), ["example-hidden-fast", "example-hidden-review"])

        let luna = try XCTUnwrap(models.first { $0.slug == "gpt-6-luna" })
        XCTAssertEqual(luna.displayName, "GPT-6-Luna")
        XCTAssertEqual(luna.efforts.map(\.id), ["low", "medium", "high", "xhigh", "max"])
        XCTAssertEqual(luna.defaultEffort, "medium")
        XCTAssertEqual(luna.priority, 5)
        XCTAssertEqual(luna.serviceTiers, [.init(id: "priority", name: "Fast", description: "1.5x speed")])
        let sol = try XCTUnwrap(models.first { $0.slug == "gpt-6.1-sol" })
        XCTAssertEqual(sol.efforts.last?.id, "ultra")
        XCTAssertFalse(sol.efforts.last!.description.isEmpty)
        XCTAssertEqual(Set(models.filter { $0.efforts.contains { $0.id == "ultra" } }.map(\.slug)), ["gpt-6.1-sol", "gpt-6-astra", "gpt-6-sol", "gpt-5.6-sol", "gpt-5.6-terra"])

        XCTAssertThrowsError(try ChatGPTModels.decode(Data(#"{"data":[]}"#.utf8)))
        XCTAssertThrowsError(try ChatGPTModels.decode(Data(#"{"models":[{"visibility":"list","slug":""}]}"#.utf8)))
    }
    func testCachedCatalogRoundTripsThroughDecode() throws {
        let original = try ChatGPTModels.decode(Data(chatGPTModelsFixture.utf8))
        XCTAssertEqual(try ChatGPTModels.decode(try ChatGPTModels.encode(original)), original)
    }
}

final class ChatGPTBackendTests: XCTestCase {
    private func sse(_ events: [[String: Any]]) -> Data {
        Data(events.map { "event: \($0["type"]!)\ndata: \(String(decoding: json($0), as: UTF8.self))\n\n" }.joined().utf8)
    }
    private func completed(_ text: String, split: Bool = true) -> [[String: Any]] {
        let parts = split ? [String(text.prefix(5)), String(text.dropFirst(5))] : [text]
        return [["type": "response.created", "response": ["id": "resp_1"]]]
            + parts.map { ["type": "response.output_text.delta", "delta": $0] }
            + [["type": "response.completed", "response": ["id": "resp_1", "status": "completed"]]]
    }
    private func backend(fast: Bool = false, credentials: ChatGPTCredentials? = .fake(),
                         responses: @escaping (Int) -> StubResponse) -> (ChatGPTBackend, MemoryChatGPTStore) {
        let store = MemoryChatGPTStore(profile: credentials == nil ? nil : .fakeConnected, credentials: credentials)
        let calls = Locked(0)
        ChatGPTStub.install { request, body in
            if request.url?.host == "api.openai.com" {
                calls.value += 1
                return responses(calls.value)
            }
            return FakeIssuer.route(request, body) { _ in
                FakeIssuer.tokens(access: "fake-access-2", idToken: TestSigner.shared.token(TestSigner.claims(nonce: nil)))
            } ?? StubResponse(status: 404)
        }
        let auth = ChatGPTAuth(store: store, session: ChatGPTStub.session, openBrowser: { _ in })
        return (ChatGPTBackend(auth: auth, model: "gpt-6-luna", effort: "low", serviceTier: fast ? "priority" : nil), store)
    }
    private func stream(_ events: [[String: Any]], status: Int = 200) -> StubResponse {
        StubResponse(status: status, headers: ["Content-Type": "text/event-stream"], body: sse(events))
    }

    func testRequestShapeAndStreamedStructuredCorrection() async throws {
        let (b, _) = backend(fast: true) { _ in self.stream(self.completed(#"{"text":"This is a test."}"#)) }
        let text = try await b.correct("ths is a test.")
        XCTAssertEqual(text, "This is a test.")
        let sent = try XCTUnwrap(ChatGPTStub.requests(to: "/v1/responses").first)
        XCTAssertEqual(sent.request.httpMethod, "POST")
        XCTAssertEqual(sent.request.value(forHTTPHeaderField: "Authorization"), "Bearer fake-access-1")
        XCTAssertEqual(sent.request.value(forHTTPHeaderField: "Accept"), "text/event-stream")
        XCTAssertNil(sent.request.value(forHTTPHeaderField: "OpenAI-Organization"))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: sent.body) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "gpt-6-luna")
        XCTAssertEqual(body["instructions"] as? String, CorrectionPolicy.instructions)
        XCTAssertEqual((body["input"] as? [[String: String]])?.first, ["role": "user", "content": "ths is a test."])
        XCTAssertEqual((body["reasoning"] as? [String: String])?["effort"], "low")
        XCTAssertEqual(body["service_tier"] as? String, "priority")
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertEqual(body["stream"] as? Bool, true)
        let format = try XCTUnwrap((body["text"] as? [String: Any])?["format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_schema"); XCTAssertEqual(format["strict"] as? Bool, true)
        XCTAssertEqual(format["name"] as? String, "correction")
        XCTAssertEqual((format["schema"] as? NSDictionary), CorrectionPolicy.schema as NSDictionary)

        let wire = try JSONSerialization.jsonObject(with: ChatGPTBackend.request(model: "m", effort: "medium", serviceTier: nil, text: "a", token: "t").httpBody!) as! [String: Any]
        XCTAssertEqual(wire["service_tier"] as? String, "default")
    }

    func testStreamParsing() throws {
        var parser = ResponseStream()
        let raw = ": keepalive\r\nevent: response.output_text.delta\r\ndata: {\"type\":\"response.output_text.delta\",\"delta\":\"he\"}\r\n\r\n"
            + "data: {\"type\":\"response.output_text.delta\",\"delta\":\"llo\"}\n\ndata: {\"type\":\"response.completed\",\"response\":{}}\n\n"
        var done = false
        for byte in Array(raw.utf8) where !done { done = try parser.feed(byte) }
        XCTAssertTrue(done); XCTAssertEqual(parser.text, "hello")

        // A completed snapshot without deltas still yields its output text, even without a trailing blank line.
        var snapshot = ResponseStream()
        let completed = #"data: {"type":"response.completed","response":{"output":[{"type":"message","content":[{"type":"output_text","text":"{\"text\":\"ok\"}"}]}]}}"#
        for byte in Array(completed.utf8) { XCTAssertFalse(try snapshot.feed(byte)) }
        XCTAssertTrue(try snapshot.finish()); XCTAssertEqual(snapshot.text, #"{"text":"ok"}"#)

        for event in [#"{"type":"response.incomplete"}"#, #"{"type":"response.refusal.delta","delta":"no"}"#, "not json"] {
            var p = ResponseStream()
            XCTAssertThrowsError(try Array("data: \(event)\n\n".utf8).forEach { _ = try p.feed($0) }, event)
        }
    }

    func testIncompleteStreamsAreRejected() async throws {
        let (b, _) = backend { _ in self.stream([["type": "response.output_text.delta", "delta": #"{"text":"hello"}"#]]) }
        do { _ = try await b.correct("hello"); XCTFail("must require response.completed") } catch {
            XCTAssertTrue(error is CorrectionError)
        }
        let (wrong, _) = backend { _ in StubResponse(headers: ["Content-Type": "application/json"], body: self.sse(self.completed(#"{"text":"hello"}"#))) }
        do { _ = try await wrong.correct("hello"); XCTFail("must require an event stream") } catch {}
    }

    func testFriendlyErrorsCarryTheReasonTheCapsuleShows() {
        func reason(_ error: Error) -> CorrectionError.Reason? { (ChatGPTBackend.friendly(error) as? CorrectionError)?.reason }
        XCTAssertEqual(reason(URLError(.notConnectedToInternet)), .offline)
        XCTAssertEqual(reason(ChatGPTError.network), .offline)
        XCTAssertEqual(reason(ChatGPTError.signInRequired), .signIn)
        XCTAssertEqual(reason(ChatGPTError("usage_limit_reached", "Limit")), .limit)
        XCTAssertNil(reason(ChatGPTError("refusal", "Declined")))
    }

    func testRequestTimeoutReadsAsTooSlowNotOffline() async {
        for (failure, expected) in [(URLError.Code.timedOut, CorrectionError.Reason.slow), (.notConnectedToInternet, .offline)] {
            let (b, _) = backend { _ in StubResponse(failure: failure) }
            do { _ = try await b.correct("hello"); XCTFail("must fail") }
            catch { XCTAssertEqual((error as? CorrectionError)?.reason, expected, "\(failure)") }
        }
    }

    func testRefreshOnUnauthorizedRetriesExactlyOnce() async throws {
        let (b, store) = backend { call in call == 1 ? StubResponse(status: 401, body: json(["error": ["code": "token_expired"]])) : self.stream(self.completed(#"{"text":"Hello."}"#)) }
        let text = try await b.correct("helo.")
        XCTAssertEqual(text, "Hello.")
        let calls = ChatGPTStub.requests(to: "/v1/responses")
        XCTAssertEqual(calls.map { $0.request.value(forHTTPHeaderField: "Authorization") }, ["Bearer fake-access-1", "Bearer fake-access-2"])
        XCTAssertEqual(ChatGPTStub.requests(to: "/oauth/token").count, 1)
        XCTAssertEqual(store.savedCredentials?.tokens.accessToken, "fake-access-2")

        let (always, alwaysStore) = backend { _ in StubResponse(status: 401, body: json(["error": ["message": "echo helo."]])) }
        do { _ = try await always.correct("helo."); XCTFail("must fail") }
        catch { XCTAssertEqual(error.localizedDescription, "Sign in with ChatGPT in Settings.") }
        XCTAssertEqual(ChatGPTStub.requests(to: "/v1/responses").count, 2, "one retry only")
        XCTAssertEqual(ChatGPTStub.requests(to: "/oauth/token").count, 1)
        XCTAssertNotNil(alwaysStore.savedCredentials, "a 401 alone does not establish revocation")
    }

    func testFriendlyErrorsNeverEchoProviderText() async throws {
        let (signedOut, _) = backend(credentials: nil) { _ in self.stream([]) }
        do { _ = try await signedOut.correct("hi"); XCTFail("expected an error") } catch { XCTAssertEqual(error.localizedDescription, "Sign in with ChatGPT in Settings.") }

        let (limited, _) = backend { _ in StubResponse(status: 429, body: json(["error": ["code": "subscription_sharing_usage_limit_exceeded", "message": "echo secret draft"]])) }
        do { _ = try await limited.correct("secret draft"); XCTFail("expected an error") } catch {
            XCTAssertTrue(error.localizedDescription.contains("chatgpt.com/settings/usage"))
            XCTAssertFalse(error.localizedDescription.contains("secret draft"))
        }
        let (failed, _) = backend { _ in self.stream([["type": "response.failed", "response": ["error": ["code": "subscription_sharing_usage_limit_exceeded", "message": "echo secret draft"]]]]) }
        do { _ = try await failed.correct("secret draft"); XCTFail("expected an error") } catch {
            XCTAssertTrue(error.localizedDescription.contains("chatgpt.com/settings/usage"))
        }
        let (down, _) = backend { _ in StubResponse(status: 503, body: Data("echo secret draft".utf8)) }
        do { _ = try await down.correct("secret draft"); XCTFail("expected an error") } catch {
            XCTAssertTrue(error is CorrectionError); XCTAssertFalse(error.localizedDescription.contains("secret draft"))
        }
    }

    func testDeadline() async throws {
        do {
            _ = try await withDeadline(.milliseconds(50), orThrow: ChatGPTBackend.slow) { try await Task.sleep(for: .seconds(5)); return "late" }
            XCTFail("must time out")
        } catch { XCTAssertTrue(error.localizedDescription.contains("too long")) }
    }
}
