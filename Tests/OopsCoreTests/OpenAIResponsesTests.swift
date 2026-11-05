import XCTest
@testable import OopsCore

final class OpenAIResponsesTests: XCTestCase {
    private func configuration(_ endpoint: String = "https://api.openai.com/v1", effort: String? = nil) -> APIConfiguration {
        APIConfiguration(baseURL: URL(string: endpoint)!, model: "discovered-model", apiKey: "project-test-key", reasoningEffort: effort)
    }

    private func stream(_ events: [[String: Any]]) -> StubResponse {
        StubResponse(headers: ["Content-Type": "text/event-stream"], body: Data(events.map {
            "data: \(String(decoding: json($0), as: UTF8.self))\n\n"
        }.joined().utf8))
    }

    private func completed(_ raw: String) -> [String: Any] {
        ["type": "response.completed", "response": ["status": "completed", "output": [
            ["type": "reasoning", "summary": []],
            ["type": "message", "content": [["type": "output_text", "text": raw]]]
        ]]]
    }

    func testRoutingUsesValidatedEndpointRatherThanPresetOrName() throws {
        for endpoint in ["https://api.openai.com/v1", "https://api.openai.com/v1/", "https://api.openai.com:443/v1"] {
            XCTAssertTrue(configuration(endpoint).backend() is OpenAIResponsesBackend, endpoint)
        }
        for endpoint in ["https://api.openai.com.evil.test/v1", "http://api.openai.com/v1", "https://api.openai.com/v2",
                         "https://api.openai.com:8443/v1", "https://api.openai.com/v1?key=secret", "https://user:secret@api.openai.com/v1",
                         "https://api.openai.com/v1#fragment", "https://openrouter.ai/api/v1", "http://localhost:1234/v1"] {
            XCTAssertFalse(configuration(endpoint).usesOpenAIResponses, endpoint)
            XCTAssertTrue(configuration(endpoint).backend() is OpenAICompatibleBackend, endpoint)
        }
        XCTAssertEqual(ProviderPreset(id: "openai")?.endpoint, configuration().baseURL)
        let manual = Provider.api(name: "My key", baseURL: "https://api.openai.com/v1", preset: nil)
        XCTAssertTrue(try manual.apiBackend(model: "m", apiKey: "k") is OpenAIResponsesBackend)
        let edited = Provider.api(name: "OpenAI", baseURL: "https://example.com/v1", preset: "openai")
        XCTAssertTrue(try edited.apiBackend(model: "m", apiKey: "k") is OpenAICompatibleBackend)
    }

    func testAPIRequestAndCompletedSnapshotUseSharedCorrectionContract() async throws {
        ChatGPTStub.install { _, _ in self.stream([self.completed(#"{"text":"This is a test."}"#)]) }
        let backend = configuration().backend(session: ChatGPTStub.session)
        let corrected = try await backend.correct("ths is a test.")
        XCTAssertEqual(corrected, "This is a test.")
        let sent = try XCTUnwrap(ChatGPTStub.requests.first)
        XCTAssertEqual(sent.request.url?.absoluteString, "https://api.openai.com/v1/responses")
        XCTAssertEqual(sent.request.httpMethod, "POST")
        XCTAssertEqual(sent.request.value(forHTTPHeaderField: "Authorization"), "Bearer project-test-key")
        XCTAssertNil(sent.request.value(forHTTPHeaderField: "OpenAI-Organization"))
        let shared = try ChatGPTBackend.request(model: "discovered-model", effort: "low", serviceTier: nil,
                                               text: "ths is a test.", token: "project-test-key")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: sent.body) as? NSDictionary,
                       try JSONSerialization.jsonObject(with: XCTUnwrap(shared.httpBody)) as? NSDictionary)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: sent.body) as? [String: Any])
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertEqual(body["service_tier"] as? String, "default")
        XCTAssertEqual((body["reasoning"] as? [String: String])?["effort"], "low")
        XCTAssertEqual(body["instructions"] as? String, CorrectionPolicy.instructions)
        let explicit = configuration(effort: "medium").backend(session: ChatGPTStub.session)
        _ = try await explicit.correct("ths is a test.")
        let last = try XCTUnwrap(ChatGPTStub.requests.last)
        let explicitBody = try JSONSerialization.jsonObject(with: last.body) as! [String: Any]
        XCTAssertEqual((explicitBody["reasoning"] as? [String: String])?["effort"], "medium")
    }

    func testReasoningCapabilitiesAtTheProviderRequestSeam() async throws {
        let omitted: [String?] = [nil, "none", "low"]
        let nonReasoning = ["gpt-4.1", "gpt-4.1-mini-2025-04-14", "gpt-4o", "gpt-4o-mini-2024-07-18",
                            "chatgpt-4o-latest", "gpt-4-turbo", "gpt-4.5-preview", "gpt-3.5-turbo", "gpt-5-chat-latest", "gpt-5.1-chat-latest",
                            "ft:gpt-4.1-2025-04-14:example:custom:id"]
        let reasoning = ["gpt-5.1", "gpt-6-luna", "gpt-6.1-sol", "o3", "o4-mini", "future-discovered-model", "gpt-40",
                         "ft:gpt-5-2025-08-07:example:custom:id"]
        var cases: [(String, String?, String?)] = nonReasoning.flatMap { model in omitted.map { (model, $0, nil) } }
        cases += reasoning.map { ($0, nil, "low") }
        cases += [("gpt-5.1", "none", "none"), ("gpt-6.1-sol", "high", "high")]
        for (model, selected, expected) in cases {
            ChatGPTStub.install { _, _ in self.stream([self.completed(#"{"text":"Hello."}"#)]) }
            let provider = Provider.api(name: "OpenAI", baseURL: "https://api.openai.com/v1", preset: "openai")
            let backend = try provider.apiBackend(model: model, apiKey: "test-key", effort: selected, session: ChatGPTStub.session)
            let answer = try await backend.correct("helo.")
            XCTAssertEqual(answer, "Hello.")
            let sent = try XCTUnwrap(ChatGPTStub.requests.first)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: sent.body) as? [String: Any])
            if let expected {
                XCTAssertEqual(body["reasoning"] as? [String: String], ["effort": expected], model)
            } else {
                XCTAssertNil(body["reasoning"], model)
            }
            XCTAssertEqual(body["model"] as? String, model)
            XCTAssertEqual(body["service_tier"] as? String, "default")
            XCTAssertEqual(body["store"] as? Bool, false)
            XCTAssertEqual(ChatGPTStub.requests.count, 1, "capabilities must not introduce retries")
        }
    }

    func testCapabilityRuleDoesNotChangeSubscriptionOrGenericRequests() throws {
        let chatGPT = try ChatGPTBackend.request(model: "gpt-5.1", effort: "none", serviceTier: "priority", text: "hi", token: "t")
        let subscriptionBody = try JSONSerialization.jsonObject(with: XCTUnwrap(chatGPT.httpBody)) as! [String: Any]
        XCTAssertEqual(subscriptionBody["reasoning"] as? [String: String], ["effort": "none"])
        XCTAssertEqual(subscriptionBody["service_tier"] as? String, "priority")
        let generic = APIConfiguration(baseURL: URL(string: "https://example.com/v1")!, model: "gpt-4.1", reasoningEffort: "none")
        let genericBody = try JSONSerialization.jsonObject(with: XCTUnwrap(generic.request(for: "hi").httpBody)) as! [String: Any]
        XCTAssertEqual(genericBody["reasoning_effort"] as? String, "none")
        XCTAssertNil(genericBody["reasoning"])
    }

    func testRejectedStreamsNeverReturnPartialCorrections() async {
        let delta: [String: Any] = ["type": "response.output_text.delta", "delta": #"{"text":"Hello."}"#]
        let refusal: [String: Any] = ["type": "response.completed", "response": ["output": [
            ["type": "message", "content": [["type": "refusal", "refusal": "sensitive echo"]]]
        ]]]
        let cases = [
            stream([delta]), stream([delta, ["type": "response.incomplete"]]),
            stream([delta, ["type": "response.refusal.done"]]), stream([delta, refusal]),
            stream([["type": "response.completed"]]),
            stream([["type": "response.completed", "response": ["status": "incomplete"]]]),
            stream([completed("not correction JSON")]), stream([completed("")]),
            StubResponse(headers: ["Content-Type": "text/event-stream"], body: Data("data: not json\n\n".utf8)),
            StubResponse(body: json(completed(#"{"text":"Hello."}"#)))
        ]
        for reply in cases {
            ChatGPTStub.install { _, _ in reply }
            do { _ = try await configuration().backend(session: ChatGPTStub.session).correct("helo."); XCTFail("must reject") }
            catch { XCTAssertFalse(error.localizedDescription.contains("sensitive")) }
        }
    }

    func testAPIAccountFailuresNeverRefreshOrMentionChatGPT() async {
        let failures: [(Int, String, CorrectionError.Reason?)] = [
            (401, "invalid_api_key", .setup), (403, "permission_denied", .setup), (404, "model_not_found", .setup),
            (429, "insufficient_quota", .limit), (429, "rate_limit_exceeded", .limit), (503, "server_error", nil)
        ]
        for (status, code, reason) in failures {
            let error = ["code": code, "message": "sensitive draft project-test-key"]
            for reply in [StubResponse(status: status, body: json(["error": error])),
                          stream([["type": "response.failed", "response": ["error": error]]])] {
                ChatGPTStub.install { _, _ in reply }
                do { _ = try await configuration().backend(session: ChatGPTStub.session).correct("hello"); XCTFail("must fail") }
                catch {
                    XCTAssertEqual((error as? CorrectionError)?.reason, reason)
                    XCTAssertFalse(error.localizedDescription.contains("ChatGPT"))
                    XCTAssertFalse(error.localizedDescription.contains("sensitive"))
                    XCTAssertFalse(error.localizedDescription.contains("project-test-key"))
                    if reason == .limit { XCTAssertTrue(error.localizedDescription.contains("platform.openai.com")) }
                }
                XCTAssertEqual(ChatGPTStub.requests.count, 1)
                XCTAssertTrue(ChatGPTStub.requests(to: "/oauth/token").isEmpty)
            }
        }
    }

    func testTimeoutNetworkAndCancellationMapping() async {
        for (code, reason) in [(URLError.Code.timedOut, CorrectionError.Reason.slow), (.notConnectedToInternet, .offline)] {
            ChatGPTStub.install { _, _ in StubResponse(failure: code) }
            do { _ = try await configuration().backend(session: ChatGPTStub.session).correct("hi"); XCTFail("must fail") }
            catch { XCTAssertEqual((error as? CorrectionError)?.reason, reason) }
        }
        ChatGPTStub.install { _, _ in StubResponse(failure: .cancelled) }
        do { _ = try await configuration().backend(session: ChatGPTStub.session).correct("hi"); XCTFail("must cancel") }
        catch { XCTAssertTrue(error is CancellationError) }
        let backend = configuration().backend(session: ChatGPTStub.session)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await backend.complete("hello")
        }
        do { _ = try await cancelled.value; XCTFail("must cancel before sending") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(ChatGPTStub.requests.count, 1, "only the earlier cancelled URL request was sent")
    }
}
