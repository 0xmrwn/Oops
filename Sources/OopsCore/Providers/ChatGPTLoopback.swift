import Foundation
import Network

/// Never follows a redirect: tokens and drafts go only to the host they were addressed to.
public final class NoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    public static let shared = NoRedirect()
    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest) async -> URLRequest? { nil }
}

/// The browser's way back: an HTTP listener on 127.0.0.1 only, on a port the system picks, answering
/// `/auth/callback` once (OpenAI's sign-in page: loopback on 127.0.0.1, never `localhost`; only the
/// port may change between sign-ins). It stays up until the matching callback arrives or it is cancelled.
final class LoopbackCallback: @unchecked Sendable {
    enum Outcome { case success(code: String, clientID: String), failure(ChatGPTError) }
    struct Reply { let status: Int, body: String, outcome: Outcome? }

    private let state: String
    private let savedClientID: String?
    private let queue = DispatchQueue(label: "dev.0xmrwn.oops.chatgpt-callback")
    private let lock = NSLock()
    private var listener: NWListener?
    private var result: Result<Outcome, Error>?
    private var waiter: CheckedContinuation<Outcome, Error>?

    init(state: String, savedClientID: String?) { self.state = state; self.savedClientID = savedClientID }

    /// Starts listening and returns the port.
    func start() async throws -> Int {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        lock.withLock { self.listener = listener }
        let started = Started()
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak listener] state in
                switch state {
                case .ready:
                    guard let port = listener?.port?.rawValue else { return }
                    started.once { continuation.resume(returning: Int(port)) }
                case .failed(let error):
                    started.once { continuation.resume(throwing: error) }
                case .cancelled:
                    started.once { continuation.resume(throwing: ChatGPTError.cancelled) }
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
            listener.start(queue: queue)
        }
    }

    /// Waits for the callback. Cancelling the task ends the attempt.
    func wait() async throws -> Outcome {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let ready: Result<Outcome, Error>? = lock.withLock {
                    if result == nil { waiter = continuation }
                    return result
                }
                if let ready { continuation.resume(with: ready) }
            }
        } onCancel: { finish(.failure(CancellationError())) }
    }

    func cancel() { finish(.failure(ChatGPTError.cancelled)) }

    private func finish(_ outcome: Result<Outcome, Error>) {
        let (waiter, listener): (CheckedContinuation<Outcome, Error>?, NWListener?) = lock.withLock {
            guard result == nil else { return (nil, nil) }
            result = outcome
            defer { self.waiter = nil; self.listener = nil }
            return (self.waiter, self.listener)
        }
        listener?.cancel()
        waiter?.resume(with: outcome)
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, Data())
    }

    /// Reads up to the end of the request head; the callback has no body.
    private func receive(_ connection: NWConnection, _ buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            guard let self else { return connection.cancel() }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let port = Int(lock.withLock { listener?.port?.rawValue } ?? 0)
                let reply = Self.handle(head: String(decoding: buffer[..<end.lowerBound], as: UTF8.self), port: port,
                                        state: state, savedClientID: savedClientID)
                respond(connection, reply)
            } else if buffer.count > 16_384 {
                respond(connection, Reply(status: 431, body: Self.page("This request is too large."), outcome: nil))
            } else if complete || error != nil {
                connection.cancel()
            } else { receive(connection, buffer) }
        }
    }

    private func respond(_ connection: NWConnection, _ reply: Reply) {
        let reason = [200: "OK", 400: "Bad Request", 404: "Not Found", 405: "Method Not Allowed", 431: "Request Header Fields Too Large"][reply.status] ?? "Error"
        let body = Data(reply.body.utf8)
        let head = "HTTP/1.1 \(reply.status) \(reason)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\n"
            + "Cache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nContent-Security-Policy: default-src 'none'; style-src 'unsafe-inline'\r\n"
            + "Connection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
        if let outcome = reply.outcome { finish(.success(outcome)) }
    }

    /// Answers one request head. Only a GET of `/auth/callback` addressed to `127.0.0.1:<port>` with this
    /// attempt's `state` (once) ends the attempt; anything else is answered and ignored, so a stray or
    /// forged request can't cancel a sign-in in progress.
    static func handle(head: String, port: Int, state expected: String, savedClientID: String?) -> Reply {
        let lines = head.components(separatedBy: "\r\n")
        let request = lines.first?.split(separator: " ") ?? []
        let host = lines.dropFirst().first { $0.lowercased().hasPrefix("host:") }?.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard request.count == 3, host == "127.0.0.1:\(port)",
              let url = URLComponents(string: "http://127.0.0.1:\(port)" + request[1]), url.path == ChatGPTAuth.callbackPath
        else { return Reply(status: 404, body: page("Nothing here."), outcome: nil) }
        guard request[0] == "GET" else { return Reply(status: 405, body: page("Nothing here."), outcome: nil) }

        let items = url.queryItems ?? []
        let names = items.map(\.name)
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard names.count(where: { $0 == "state" }) == 1, value("state") == expected,
              ["code", "client_id", "error"].allSatisfy({ name in names.count(where: { $0 == name }) <= 1 }) else {
            return Reply(status: 400, body: page("This sign-in link doesn’t match the one Oops started. Go back to Oops and try again."), outcome: nil)
        }

        if let error = value("error") {
            let failure = ChatGPTError.known(error) ?? ChatGPTError(error, "ChatGPT didn’t complete the sign-in. Try again.")
            return Reply(status: 200, body: page(failure.message), outcome: .failure(failure))
        }
        guard let code = value("code"), !code.isEmpty else {
            let failure = ChatGPTError.named("invalid_callback")
            return Reply(status: 200, body: page(failure.message), outcome: .failure(failure))
        }
        // A new registration must name its issued client; a returning one may omit it but never change it.
        let returned = value("client_id")
        let clientID: String?
        if let savedClientID { clientID = returned == nil || returned == savedClientID ? savedClientID : nil }
        else { clientID = returned.flatMap { $0.isEmpty || $0 == ChatGPTAuth.registrationClient ? nil : $0 } }
        guard let clientID else {
            let failure = ChatGPTError.named("registration_incomplete")
            return Reply(status: 200, body: page(failure.message), outcome: .failure(failure))
        }
        return Reply(status: 200, body: page("You’re signed in with ChatGPT. You can close this tab and go back to Oops."),
                     outcome: .success(code: code, clientID: clientID))
    }

    private static func page(_ message: String) -> String {
        let escaped = message.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        return """
        <!doctype html><html lang="en"><head><meta charset="utf-8"><title>Oops</title>
        <meta name="viewport" content="width=device-width, initial-scale=1"><style>
        body{font:17px -apple-system,system-ui,sans-serif;display:grid;place-items:center;min-height:90vh;margin:0 24px;color:#1d1d1f;background:#fff}
        @media (prefers-color-scheme:dark){body{color:#f5f5f7;background:#1d1d1f}}p{max-width:30em;text-align:center;line-height:1.45}
        </style></head><body><p>\(escaped)</p></body></html>
        """
    }
}

/// Resumes a continuation once, whatever the listener reports afterwards.
private final class Started: @unchecked Sendable {
    private let lock = NSLock(); private var done = false
    func once(_ body: () -> Void) {
        let first = lock.withLock { defer { done = true }; return !done }
        if first { body() }
    }
}
