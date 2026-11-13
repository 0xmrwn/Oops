import XCTest
@testable import OopsCore

final class OpenAICompatibleTests: XCTestCase {
    private let gemini = URL(string: "https://generativelanguage.googleapis.com/v1beta/openai")!
    private func wire(_ configuration: APIConfiguration) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: XCTUnwrap(configuration.request(for: "a", instructions: CorrectionPolicy.instructions).httpBody)) as! [String: Any]
    }

    func testReasoningEffortIsSentOnlyWhenSet() throws {
        XCTAssertNil(try wire(APIConfiguration(baseURL: gemini, model: "m", apiKey: "k"))["reasoning_effort"])
        let body = try wire(APIConfiguration(baseURL: gemini, model: "m", apiKey: "k", reasoningEffort: "low"))
        XCTAssertEqual(body["reasoning_effort"] as? String, "low")
        XCTAssertEqual(body["model"] as? String, "m")
    }

    func testModelsDecodeStripsGeminiPrefixAndKeepsDisplayNames() throws {
        let models = try OpenAICompatibleModels.decode(json(["object": "list", "data": [
            ["id": "models/gemini-3.8-flash", "object": "model", "owned_by": "google"],
            ["id": "gpt-x", "display_name": "GPT X"],
            ["id": "gemini-3.8-flash"], ["id": ""], ["id": 7], "junk",
        ]]))
        XCTAssertEqual(models, [.init(id: "gemini-3.8-flash", name: "gemini-3.8-flash"), .init(id: "gpt-x", name: "GPT X")])
        for bad in [Data("not json".utf8), json(["models": []]), json(["data": "x"]), json(["data": [["id": ""]]])] {
            XCTAssertThrowsError(try OpenAICompatibleModels.decode(bad))
        }
        XCTAssertThrowsError(try OpenAICompatibleModels.decode(Data(count: 4_000_001)))
    }

    func testModelsListSendsKeyAndDecodes() async throws {
        ChatGPTStub.install { _, _ in StubResponse(body: json(["data": [["id": "models/gemini-4-argon"]]])) }
        let models = try await OpenAICompatibleModels.list(baseURL: gemini, apiKey: "test-key", session: ChatGPTStub.session)
        XCTAssertEqual(models.map(\.id), ["gemini-4-argon"])
        let request = try XCTUnwrap(ChatGPTStub.requests.first?.request)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/v1beta/openai/models")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")

        ChatGPTStub.install { _, _ in StubResponse(body: json(["data": [["id": "local"]]])) }
        _ = try await OpenAICompatibleModels.list(baseURL: URL(string: "http://localhost:1234/v1")!, session: ChatGPTStub.session)
        XCTAssertNil(ChatGPTStub.requests.first?.request.value(forHTTPHeaderField: "Authorization"))
    }

    func testStrictSchemaOnTheWireAndOneCompleteAnswer() async throws {
        ChatGPTStub.install { _, _ in StubResponse(body: json(["choices": [["finish_reason": "stop", "message": ["content": #"{"text":"This is a test."}"#]]]])) }
        let backend = OpenAICompatibleBackend(configuration: APIConfiguration(baseURL: gemini, model: "m", apiKey: "k"), session: ChatGPTStub.session)
        let text = try await backend.correct("ths is a test.")
        XCTAssertEqual(text, "This is a test.")
        XCTAssertEqual(ChatGPTStub.requests.first?.request.url?.path, "/v1beta/openai/chat/completions")
        let format = try XCTUnwrap(wire(APIConfiguration(baseURL: gemini, model: "m"))["response_format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_schema")
        XCTAssertEqual((format["json_schema"] as? [String: Any])?["strict"] as? Bool, true)
        for (content, finish) in [(#"{"text":"hello"}"#, "length"), ("hello", "stop")] {
            ChatGPTStub.install { _, _ in StubResponse(body: json(["choices": [["finish_reason": finish, "message": ["content": content]]]])) }
            do { _ = try await backend.correct("hello"); XCTFail("Should reject \(finish) \(content)") } catch {}
        }
    }

    func testCorrectionFailuresCarryTheReasonTheCapsuleShows() async {
        let backend = OpenAICompatibleBackend(configuration: APIConfiguration(baseURL: gemini, model: "m", apiKey: "k"), session: ChatGPTStub.session)
        for (status, reason) in [(401, CorrectionError.Reason.setup), (429, .limit), (500, nil)] {
            ChatGPTStub.install { _, _ in StubResponse(status: status, body: Data("sensitive provider echo".utf8)) }
            do { _ = try await backend.correct("hello"); XCTFail("Should reject \(status)") }
            catch {
                XCTAssertEqual((error as? CorrectionError)?.reason, reason, "\(status)")
                XCTAssertFalse(error.localizedDescription.contains("sensitive"))
            }
        }
    }

    func testModelsListErrorsAreShortAndNeverEchoTheBody() async {
        for status in [401, 500] {
            ChatGPTStub.install { _, _ in StubResponse(status: status, body: Data("sensitive provider echo test-key".utf8)) }
            do { _ = try await OpenAICompatibleModels.list(baseURL: gemini, apiKey: "test-key", session: ChatGPTStub.session); XCTFail("Should reject") }
            catch {
                XCTAssertTrue(error is CorrectionError)
                XCTAssertFalse(error.localizedDescription.contains("sensitive"))
                XCTAssertFalse(error.localizedDescription.contains("test-key"))
            }
        }
    }

    func testModelDiscoveryTimeoutGivesRetryFeedback() async {
        ChatGPTStub.install { _, _ in StubResponse(failure: .timedOut) }
        do {
            _ = try await OpenAICompatibleModels.list(baseURL: gemini, apiKey: "test-key", session: ChatGPTStub.session)
            XCTFail("Should time out")
        } catch {
            XCTAssertEqual(error.localizedDescription, "The provider took too long to list models. Try again.")
        }
    }

    func testUnsafeBaseURLsAreRejectedBeforeAnyRequest() async {
        ChatGPTStub.install { _, _ in StubResponse(body: json(["data": [["id": "m"]]])) }
        for url in ["http://example.com/v1", "https://user:secret@example.com/v1", "https://example.com/v1?key=secret", "https://example.com/v1#x", "ftp://localhost/v1"] {
            do { _ = try await OpenAICompatibleModels.list(baseURL: URL(string: url)!, session: ChatGPTStub.session); XCTFail("Should reject \(url)") }
            catch { XCTAssertTrue(error is CorrectionError) }
        }
        XCTAssertTrue(ChatGPTStub.requests.isEmpty)
        for url in ["https://example.com/v1", "http://localhost:1234/v1", "http://127.0.0.1:1234/v1", "http://[::1]:1234/v1"] {
            XCTAssertTrue(APIConfiguration.isSafe(URL(string: url)!), url)
        }
    }

    func testPresetsAreDurableFactsOnly() {
        let ids = ProviderPreset.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        for preset in ProviderPreset.all {
            XCTAssertTrue(APIConfiguration.isSafe(preset.endpoint), preset.id)
            XCTAssertEqual(preset.endpoint.host == "localhost", preset.local, preset.id)
            XCTAssertEqual(ProviderPreset(id: preset.id), preset)
        }
        XCTAssertEqual(ProviderPreset.all.filter(\.local).map(\.name), ["LM Studio", "Ollama"])
        XCTAssertEqual(ProviderPreset.all.map(\.name), ProviderPreset.all.map(\.name).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
        XCTAssertNil(ProviderPreset(id: "Gemini"))
    }
}
