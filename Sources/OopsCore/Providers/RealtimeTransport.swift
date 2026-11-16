import Foundation

/// Opens a WebSocket for one dictation. The seam exists so tests drive the client without a socket when they need to;
/// the stub in the tests also speaks to the real transport over the loopback.
public protocol RealtimeTransport: Sendable {
    func connect(_ request: URLRequest) async throws -> any RealtimeSocket
}

/// One open WebSocket carrying text frames.
public protocol RealtimeSocket: Sendable {
    func send(_ text: String) async throws
    /// The next text frame; throws when the connection ends.
    func receive() async throws -> String
    func close()
}

/// A WebSocket that never opened: the HTTP status the service answered the upgrade with, when it answered, and the
/// system's error code. Neither carries the request.
public struct RealtimeHandshakeError: Error, Equatable, Sendable {
    public let status: Int?
    public let domain: String, code: Int
}

/// The system's WebSocket. Nothing here logs the request: it carries the API key.
public struct URLSessionRealtimeTransport: RealtimeTransport {
    public init() {}

    public func connect(_ request: URLRequest) async throws -> any RealtimeSocket {
        let configuration = URLSessionConfiguration.ephemeral
        // A dictation that can't connect fails at once rather than waiting for the network to come back.
        configuration.waitsForConnectivity = false
        let handshake = Handshake()
        let session = URLSession(configuration: configuration, delegate: handshake, delegateQueue: nil)
        let task = session.webSocketTask(with: request)
        task.resume()
        do {
            try await withTaskCancellationHandler { try await handshake.outcome() } onCancel: { task.cancel() }
            try Task.checkCancellation()
        } catch {
            // No socket is handed back to close, so the session is let go here.
            task.cancel()
            session.invalidateAndCancel()
            throw error
        }
        return URLSessionRealtimeSocket(task: task, session: session)
    }
}

/// Tells whether the upgrade opened a WebSocket. A refused upgrade (a bad key, a wrong URL) completes the task with
/// an error and never opens it; a ping sent meanwhile is never answered, so the delegate is what says so.
private final class Handshake: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Void, any Error>?
    private var waiter: CheckedContinuation<Void, any Error>?

    func outcome() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            lock.lock()
            if let result { lock.unlock(); continuation.resume(with: result) } else { waiter = continuation; lock.unlock() }
        }
    }

    private func settle(_ outcome: Result<Void, any Error>) {
        lock.lock()
        guard result == nil else { return lock.unlock() }
        result = outcome
        let waiting = waiter
        waiter = nil
        lock.unlock()
        waiting?.resume(with: outcome)
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        settle(.success(()))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: any Error?) {
        let reason = error as NSError?
        settle(.failure(RealtimeHandshakeError(status: (task.response as? HTTPURLResponse)?.statusCode,
                                               domain: reason?.domain ?? "", code: reason?.code ?? 0)))
    }
}

private struct URLSessionRealtimeSocket: RealtimeSocket {
    let task: URLSessionWebSocketTask
    let session: URLSession

    func send(_ text: String) async throws { try await task.send(.string(text)) }

    func receive() async throws -> String {
        switch try await task.receive() {
        case let .string(text): return text
        // Every event is JSON text; a binary frame is none the client knows, which parses as `.other`.
        case .data: return "{}"
        @unknown default: return "{}"
        }
    }

    func close() {
        task.cancel(with: .normalClosure, reason: nil)
        session.finishTasksAndInvalidate()
    }
}
