import Foundation
import XCTest
import OopsCore
@testable import OopsEval

final class ResponsesLaneTests: XCTestCase {
    private func lane(status: Int = 200, body: String) -> ChatGPTLane {
        EvalResponsesStub.install(status: status, body: body)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [EvalResponsesStub.self]
        return ChatGPTLane(apiKey: "synthetic-key", model: "gpt-6.1-sol", effort: "low", session: URLSession(configuration: config))
    }

    func testProjectKeyUsesCurrentAppRequestAndParserWithUsage() async throws {
        let stream = #"""
        data: {"type":"response.output_text.delta","delta":"{\"text\":\"the cat\"}"}

        data: {"type":"response.completed","response":{"id":"resp_test","model":"gpt-6.1-sol","status":"completed","usage":{"input_tokens":12,"output_tokens":6,"output_tokens_details":{"reasoning_tokens":2},"input_tokens_details":{"cached_tokens":4}}}}


        """#
        let answer = await lane(body: stream).send("teh cat")
        XCTAssertEqual(answer.raw, #"{"text":"the cat"}"#)
        XCTAssertEqual(answer.modelReported, "gpt-6.1-sol")
        XCTAssertEqual(answer.tokens?.in, 12); XCTAssertEqual(answer.tokens?.reasoning, 2)
        XCTAssertEqual(answer.tokens?.cached, 4); XCTAssertEqual(answer.finish, "completed")
        XCTAssertNotNil(answer.ttft); XCTAssertNotNil(answer.ttfc)
        let sent = try XCTUnwrap(EvalResponsesStub.requests.first)
        let expected = try ChatGPTBackend.request(model: "gpt-6.1-sol", effort: "low", serviceTier: nil, text: "teh cat", token: "synthetic-key")
        XCTAssertEqual(sent.url, expected.url)
        XCTAssertEqual(sent.url?.absoluteString, "https://api.openai.com/v1/responses")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-key")
        let body = try XCTUnwrap(sent.httpBody)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: body) as? NSDictionary,
                       try JSONSerialization.jsonObject(with: XCTUnwrap(expected.httpBody)) as? NSDictionary)
        XCTAssertEqual(EvalResponsesStub.requests.count, 1)
    }

    func testProjectKeyRejectionDoesNotRefreshSubscriptionOrExposeBody() async {
        let answer = await lane(status: 401, body: #"{"error":{"code":"invalid_api_key","message":"private provider echo"}}"#).send("teh cat")
        XCTAssertEqual(answer.status, 401)
        XCTAssertEqual(answer.error, "chatgpt: invalid_api_key")
        XCTAssertNil(answer.raw); XCTAssertEqual(EvalResponsesStub.requests.count, 1)
    }

    func testProjectQuotaIsDeferredAndPartialStreamsAreNotAccepted() async {
        let limited = await lane(status: 429, body: #"{"error":{"code":"insufficient_quota"}}"#).send("teh cat")
        XCTAssertEqual(limited.limit?.daily, true)
        let partial = await lane(body: "data: {\"type\":\"response.output_text.delta\",\"delta\":\"partial\"}\n\n").send("teh cat")
        XCTAssertNil(partial.raw); XCTAssertTrue(partial.transient)
        XCTAssertEqual(partial.error, "chatgpt: stream_interrupted")
    }
}

/// Every request terminates here; tests cannot reach a provider or read subscription credentials.
private final class EvalResponsesStub: URLProtocol {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var status = 200
    private nonisolated(unsafe) static var body = Data()
    private nonisolated(unsafe) static var log: [URLRequest] = []
    static var requests: [URLRequest] { lock.withLock { log } }
    static func install(status: Int, body: String) {
        lock.withLock { self.status = status; self.body = Data(body.utf8); log = [] }
    }
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var sent = request
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            sent.httpBody = data
        }
        let (status, body) = Self.lock.withLock { Self.log.append(sent); return (Self.status, Self.body) }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
