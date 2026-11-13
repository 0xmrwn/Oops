import XCTest
@testable import OopsCore

final class ModelsDevFeedTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("oops-models-dev-" + UUID().uuidString)
        ModelsDevStub.reply = { _ in StubResponse(status: 599) }
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private var client: ModelsDevClient { ModelsDevClient(session: ModelsDevStub.session, directory: directory) }
    private static func ok(_ body: String = modelsDevFixture, etag: String = #""v1""#) -> StubResponse {
        StubResponse(headers: ["Content-Type": "application/json", "ETag": etag], body: Data(body.utf8))
    }

    func testDecodesTheFeedAndSkipsWhatItCannotRead() throws {
        let feed = try ModelsDevFeed.decode(Data(modelsDevFixture.utf8))
        XCTAssertEqual(feed.providers.keys.sorted(), ["groq", "llmgateway", "mistral", "vercel"])
        let turbo = try XCTUnwrap(feed.model(provider: "groq", id: "whisper-large-v3-turbo"))
        XCTAssertEqual(turbo.type, "transcription")
        XCTAssertEqual(turbo.canonicalID, "openai/whisper-large-v3-turbo")
        XCTAssertEqual(turbo.modalities?.input, ["audio"])
        let odd = #"{"a":{"id":"a","models":{"good":{"id":"good","future":{"x":1}},"bad":{"name":3}}},"b":{"models":{}},"c":7}"#
        let tolerant = try ModelsDevFeed.decode(Data(odd.utf8))
        XCTAssertEqual(tolerant.providers.keys.sorted(), ["a"])
        XCTAssertEqual(tolerant.providers["a"]?.models.keys.sorted(), ["good"])
    }

    func testLooksUpByProviderThenCanonicalID() throws {
        let feed = try ModelsDevFeed.decode(Data(modelsDevFixture.utf8))
        XCTAssertEqual(feed.model(provider: "mistral", id: "voxtral-mini-latest")?.name, "Voxtral Mini (latest)")
        XCTAssertEqual(feed.model(provider: "openai", id: "whisper-1")?.id, "openai/whisper-1")
        XCTAssertEqual(feed.model(provider: "google", id: "gemini-3.5-transcribe")?.id, "google/gemini-3.5-transcribe")
        XCTAssertEqual(feed.model(provider: nil, id: "openai/whisper-large-v3")?.id, "whisper-large-v3")
        XCTAssertNil(feed.model(provider: "mistral", id: "mistral-small-latest"))
        XCTAssertNil(feed.model(provider: nil, id: "whisper-1"))
        XCTAssertEqual(ModelsDevFeed.providerID(.api(preset: "gemini")), "google")
        XCTAssertEqual(ModelsDevFeed.providerID(.api(preset: "ollama")), "ollama")
        XCTAssertNil(ModelsDevFeed.providerID(.api(preset: nil)))
        XCTAssertNil(ModelsDevFeed.providerID(.chatGPT))
    }

    func testFirstLoadCachesTheFeedAndItsETag() async throws {
        ModelsDevStub.reply = { _ in Self.ok() }
        let loaded = await client.load()
        XCTAssertEqual(loaded?.providers.count, 4)
        let request = try XCTUnwrap(ModelsDevStub.requests.first)
        XCTAssertEqual(request.url, ModelsDevClient.feedURL)
        XCTAssertNil(request.value(forHTTPHeaderField: "If-None-Match"))
        XCTAssertEqual(client.cached(), loaded)
    }

    func testRevalidationSendsTheStoredETagAndA304KeepsTheCache() async {
        ModelsDevStub.reply = { _ in Self.ok() }
        let first = await client.load()
        ModelsDevStub.reply = { _ in StubResponse(status: 304, body: Data()) }
        let second = await client.load()
        XCTAssertEqual(ModelsDevStub.requests.last?.value(forHTTPHeaderField: "If-None-Match"), #""v1""#)
        XCTAssertEqual(second, first)
        XCTAssertNotNil(second)
    }

    func testA200ReplacesTheCacheAndItsETag() async {
        ModelsDevStub.reply = { _ in Self.ok() }
        _ = await client.load()
        ModelsDevStub.reply = { _ in Self.ok(#"{"groq":{"id":"groq","models":{}}}"#, etag: #""v2""#) }
        let replaced = await client.load()
        XCTAssertEqual(replaced?.providers.keys.sorted(), ["groq"])
        XCTAssertEqual(client.cached(), replaced)
        _ = await client.load()
        XCTAssertEqual(ModelsDevStub.requests.last?.value(forHTTPHeaderField: "If-None-Match"), #""v2""#)
    }

    func testFailuresFallBackToTheCache() async {
        ModelsDevStub.reply = { _ in Self.ok() }
        let first = await client.load()
        for failure in [StubResponse(failure: .notConnectedToInternet), StubResponse(status: 500), Self.ok("not json", etag: #""v3""#)] {
            ModelsDevStub.reply = { _ in failure }
            let loaded = await client.load()
            XCTAssertEqual(loaded, first)
        }
        // A body that didn't decode left the copy and its tag alone.
        _ = await client.load()
        XCTAssertEqual(ModelsDevStub.requests.last?.value(forHTTPHeaderField: "If-None-Match"), #""v1""#)
    }

    func testNoCacheAndAFailureIsNoFeed() async {
        ModelsDevStub.reply = { _ in StubResponse(failure: .notConnectedToInternet) }
        let loaded = await client.load()
        XCTAssertNil(loaded)
        XCTAssertNil(client.cached())
    }
}

/// Answers models.dev requests in tests; nothing reaches the network.
final class ModelsDevStub: URLProtocol {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var handler: @Sendable (URLRequest) -> StubResponse = { _ in StubResponse(status: 599) }
    private nonisolated(unsafe) static var log: [URLRequest] = []
    static var reply: @Sendable (URLRequest) -> StubResponse {
        get { lock.withLock { handler } }
        set { lock.withLock { handler = newValue; log = [] } }
    }
    static var requests: [URLRequest] { lock.withLock { log } }
    static var session: URLSession {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ModelsDevStub.self]
        return URLSession(configuration: config)
    }
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let reply = Self.lock.withLock { Self.log.append(request); return Self.handler }(request)
        if let failure = reply.failure { client?.urlProtocol(self, didFailWithError: URLError(failure)); return }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
