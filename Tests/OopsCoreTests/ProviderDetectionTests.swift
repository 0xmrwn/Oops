import XCTest
@testable import OopsCore

final class ProviderDetectionTests: XCTestCase {
    private let lmStudio = URL(string: "http://localhost:1234/v1")!
    private let signedIn = ClaudeCode.Status.signedIn(.init(email: nil, organization: nil, plan: nil))
    private let running = LocalServer.running([.init(id: "m", name: "m")])

    private func probe(status: Int = 200, body: Data = json(["data": [["id": "qwen"]]]), at url: URL? = nil) async -> LocalServer? {
        ChatGPTStub.install { _, _ in StubResponse(status: status, body: body) }
        return await OpenAICompatibleModels.probe(baseURL: url ?? lmStudio, session: ChatGPTStub.session)
    }

    func testProbeReadsTheModelsOfARunningServer() async throws {
        let server = await probe()
        XCTAssertEqual(server, .running([.init(id: "qwen", name: "qwen")]))
        let request = try XCTUnwrap(ChatGPTStub.requests.first?.request)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/v1/models")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testProbeSeesAServerThatWantsAKey() async {
        let unauthorized = await probe(status: 401), forbidden = await probe(status: 403)
        XCTAssertEqual(unauthorized, .needsKey)
        XCTAssertEqual(forbidden, .needsKey)
    }

    func testProbeIgnoresEverythingElse() async {
        let failed = await probe(status: 500), junk = await probe(body: Data("<html>not a model list</html>".utf8))
        let empty = await probe(body: json(["data": []]))
        XCTAssertNil(failed)
        XCTAssertNil(junk)
        XCTAssertNil(empty)
    }

    func testProbeRefusesAnyHostButThisMac() async {
        for address in ["https://api.openai.com/v1", "http://192.168.1.20:1234/v1", "http://example.com/v1"] {
            let server = await probe(at: URL(string: address)!)
            XCTAssertNil(server, address)
            XCTAssertTrue(ChatGPTStub.requests.isEmpty, address)
        }
    }

    func testProbeAnswersWhenNothingListens() async {
        // The port is closed, so this also covers a refused connection through the default session.
        let server = await OpenAICompatibleModels.probe(baseURL: URL(string: "http://127.0.0.1:9/v1")!)
        XCTAssertNil(server)
    }

    func testNothingFoundOffersChatGPTThenClaudeAndSelectsNothing() {
        let findings = ProviderFindings()
        XCTAssertEqual(findings.rows, [.chatGPT, .claude])
        XCTAssertNil(findings.preferred)
    }

    func testAccountsLeadInAFixedOrderWhateverIsUsable() {
        let findings = ProviderFindings(claude: signedIn, local: ["lmstudio": running])
        XCTAssertEqual(findings.rows, [.chatGPT, .claude, .local("lmstudio")])
        XCTAssertEqual(ProviderFindings(chatGPTSignedIn: true, local: ["lmstudio": running]).rows, [.chatGPT, .claude, .local("lmstudio")])
        XCTAssertEqual(findings.preferred, .claude)
        XCTAssertTrue(findings.isUsable(.local("lmstudio")))
        XCTAssertFalse(findings.isUsable(.chatGPT))
    }

    func testChatGPTComesBeforeClaudeInEveryState() throws {
        let claude: [ClaudeCode.Status] = [.notInstalled, .signedOut, signedIn]
        for status in claude {
            for chatGPTSignedIn in [false, true] {
                XCTAssertEqual(ProviderFindings(claude: status, chatGPTSignedIn: chatGPTSignedIn).rows, [.chatGPT, .claude])
                let rows = ProviderFindings(claude: status, chatGPTSignedIn: chatGPTSignedIn, local: ["lmstudio": running]).rows
                XCTAssertLessThan(try XCTUnwrap(rows.firstIndex(of: .chatGPT)), try XCTUnwrap(rows.firstIndex(of: .claude)))
            }
        }
        XCTAssertNil(ProviderFindings(claude: .signedOut).preferred)
        XCTAssertEqual(ProviderFindings(claude: signedIn, chatGPTSignedIn: true).preferred, .chatGPT)
    }

    func testChatGPTSignedInIsPreferredOverAnInstallableClaude() {
        let findings = ProviderFindings(claude: .notInstalled, chatGPTSignedIn: true)
        XCTAssertEqual(findings.rows, [.chatGPT, .claude])
        XCTAssertEqual(findings.preferred, .chatGPT)
    }

    func testServersFollowTheAccountsAndOneNeedingAKeyIsNotUsable() {
        let findings = ProviderFindings(claude: .signedOut, local: ["ollama": .needsKey, "lmstudio": running])
        XCTAssertEqual(findings.rows, [.chatGPT, .claude, .local("lmstudio"), .local("ollama")])
        XCTAssertFalse(findings.isUsable(.local("ollama")))
        XCTAssertEqual(findings.preferred, .local("lmstudio"))
        XCTAssertNil(ProviderFindings(local: ["ollama": .needsKey]).preferred)
    }
}
