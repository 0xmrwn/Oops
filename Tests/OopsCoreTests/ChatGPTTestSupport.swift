import Foundation
import Security
@testable import OopsCore

/// In-memory store: tests never touch the login Keychain.
final class MemoryChatGPTStore: ChatGPTStore, @unchecked Sendable {
    private let lock = NSLock()
    private var profile: ChatGPTProfile?
    private var credentials: ChatGPTCredentials?
    init(profile: ChatGPTProfile? = nil, credentials: ChatGPTCredentials? = nil) { self.profile = profile; self.credentials = credentials }
    var savedProfile: ChatGPTProfile? { lock.withLock { profile } }
    var savedCredentials: ChatGPTCredentials? { lock.withLock { credentials } }
    func readProfile() throws -> ChatGPTProfile? { lock.withLock { profile } }
    func writeProfile(_ profile: ChatGPTProfile) throws { lock.withLock { self.profile = profile } }
    func readCredentials() throws -> ChatGPTCredentials? { lock.withLock { credentials } }
    func writeCredentials(_ credentials: ChatGPTCredentials) throws { lock.withLock { self.credentials = credentials } }
    func deleteCredentials() throws { lock.withLock { credentials = nil } }
}

struct StubResponse {
    var status = 200; var headers: [String: String] = ["Content-Type": "application/json"]; var body = Data()
    /// Fails the request instead of answering, like a timeout or a dropped connection.
    var failure: URLError.Code?
}

/// Routes every request from a stubbed session; nothing reaches the network.
final class ChatGPTStub: URLProtocol {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var handler: (URLRequest, Data) -> StubResponse = { _, _ in StubResponse(status: 599) }
    private nonisolated(unsafe) static var log: [(URLRequest, Data)] = []
    static func install(_ handler: @escaping (URLRequest, Data) -> StubResponse) { lock.withLock { self.handler = handler; log = [] } }
    static var requests: [(request: URLRequest, body: Data)] { lock.withLock { log.map { ($0.0, $0.1) } } }
    static func requests(to path: String) -> [(request: URLRequest, body: Data)] { requests.filter { $0.request.url?.path == path } }
    static var session: URLSession {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ChatGPTStub.self]
        return URLSession(configuration: config)
    }
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; body.append(buffer, count: n) }
        }
        let handler = Self.lock.withLock { Self.log.append((request, body)); return Self.handler }
        let reply = handler(request, body)
        if let failure = reply.failure { client?.urlProtocol(self, didFailWithError: URLError(failure)); return }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

// swiftlint:disable:next force_try
func json(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object) }
func form(_ body: Data) -> [String: String] {
    var result: [String: String] = [:]
    for pair in String(decoding: body, as: UTF8.self).split(separator: "&") {
        let parts = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? "" }
        result[parts[0]] = parts.count > 1 ? parts[1] : ""
    }
    return result
}

/// A throwaway in-memory RSA key (never persisted) standing in for OpenAI's signing key. Shared by
/// tests on any thread: a `SecKey` never changes once made.
struct TestSigner: @unchecked Sendable {
    static let shared = TestSigner(kid: "test-key")
    static let other = TestSigner(kid: "test-key")
    let kid: String
    let privateKey: SecKey
    init(kid: String) {
        self.kid = kid
        privateKey = SecKeyCreateRandomKey([kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048] as CFDictionary, nil)!
    }
    var publicKey: SecKey { SecKeyCopyPublicKey(privateKey)! }
    var jwks: [String: Any] {
        // PKCS#1 RSAPublicKey: SEQUENCE { INTEGER n, INTEGER e }.
        let der = [UInt8](SecKeyCopyExternalRepresentation(publicKey, nil)! as Data)
        var index = 0
        func header() -> Int {
            index += 1
            let first = Int(der[index]); index += 1
            guard first & 0x80 != 0 else { return first }
            var length = 0
            for _ in 0..<(first & 0x7f) { length = length << 8 | Int(der[index]); index += 1 }
            return length
        }
        _ = header()
        let nLength = header(); let n = Data(der[index..<index + nLength].drop(while: { $0 == 0 })); index += nLength
        let eLength = header(); let e = Data(der[index..<index + eLength])
        return ["keys": [["kty": "RSA", "kid": kid, "use": "sig", "alg": "RS256",
                          "n": ChatGPTAuth.base64URL(n), "e": ChatGPTAuth.base64URL(e)]]]
    }
    func token(_ claims: [String: Any], alg: String = "RS256") -> String {
        let head = ChatGPTAuth.base64URL(json(["alg": alg, "kid": kid, "typ": "JWT"]))
        let body = ChatGPTAuth.base64URL(json(claims))
        let signature = SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256, Data("\(head).\(body)".utf8) as CFData, nil)! as Data
        return "\(head).\(body).\(ChatGPTAuth.base64URL(signature))"
    }
    static func claims(client: String = "client_test", nonce: String? = "nonce-1", subject: String = "user-1", expires: TimeInterval = 3600) -> [String: Any] {
        let now = Date().timeIntervalSince1970
        var claims: [String: Any] = ["iss": "https://auth.openai.com", "aud": [client], "sub": subject, "iat": now, "exp": now + expires,
                                     "email": "fake@example.invalid", "name": "Test User",
                                     "https://api.openai.com/auth": ["chatgpt_plan_type": "pro"]]
        if let nonce { claims["nonce"] = nonce }
        return claims
    }
}

/// Fake authorization server: discovery, JWKS, token and revocation endpoints on auth.openai.com.
enum FakeIssuer {
    static let discovery: [String: String] = [
        "issuer": "https://auth.openai.com", "authorization_endpoint": "https://auth.openai.com/oauth/authorize",
        "token_endpoint": "https://auth.openai.com/oauth/token", "jwks_uri": "https://auth.openai.com/.well-known/jwks.json",
        "revocation_endpoint": "https://auth.openai.com/oauth/revoke"]
    static func route(_ request: URLRequest, _ body: Data, token: (([String: String]) -> StubResponse)? = nil) -> StubResponse? {
        switch request.url?.path {
        case "/.well-known/openid-configuration": return StubResponse(body: json(discovery))
        case "/.well-known/jwks.json": return StubResponse(body: json(TestSigner.shared.jwks))
        case "/oauth/token": return token?(form(body)) ?? StubResponse(status: 500)
        case "/oauth/revoke": return StubResponse(body: Data())
        default: return nil
        }
    }
    static func tokens(access: String, refresh: String = "fake-refresh-2", scope: String? = ChatGPTAuth.scopes, idToken: String? = nil) -> StubResponse {
        var object: [String: Any] = ["access_token": access, "refresh_token": refresh, "token_type": "Bearer", "expires_in": 3600]
        if let scope { object["scope"] = scope }
        if let idToken { object["id_token"] = idToken }
        return StubResponse(body: json(object))
    }
}

extension ChatGPTCredentials {
    static func fake(access: String = "fake-access-1", expiresIn: TimeInterval = 3600, scopes: [String] = ChatGPTAuth.scopes.split(separator: " ").map(String.init)) -> ChatGPTCredentials {
        ChatGPTCredentials(clientID: "client_test", scopes: scopes, idToken: "fake.id.token",
                           tokens: ChatGPTTokens(accessToken: access, refreshToken: "fake-refresh-1", expiresAt: Date().addingTimeInterval(expiresIn), earliestRefreshAt: nil))
    }
}
extension ChatGPTProfile {
    static let fakeConnected = ChatGPTProfile(hostID: "urn:uuid:00000000-0000-4000-8000-000000000000", clientID: "client_test", subject: "user-1",
                                              identity: ChatGPTIdentity(email: "fake@example.invalid"), state: .connected)
}
