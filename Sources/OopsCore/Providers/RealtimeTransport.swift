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

/// The system's WebSocket. Nothing here logs the request: it carries the API key.
public struct URLSessionRealtimeTransport: RealtimeTransport {
    public init() {}

    public func connect(_ request: URLRequest) async throws -> any RealtimeSocket {
        let configuration = URLSessionConfiguration.ephemeral
        // A dictation that can't connect fails at once rather than waiting for the network to come back.
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        let task = session.webSocketTask(with: request)
        task.resume()
        // The handshake's outcome only surfaces on the first receive or send; a ping makes it explicit.
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    task.sendPing { error in
                        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                    }
                }
            } onCancel: { task.cancel() }
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
