import CryptoKit
import Foundation
import Network
import Synchronization
import XCTest
@testable import OopsCore

/// A tiny HTTP server on 127.0.0.1 and an ephemeral port: it serves `body`, honours `Range`, and can be told, one
/// request at a time, to cut the connection mid-body, hold it open, ignore the range or refuse it.
final class RangeServer: @unchecked Sendable {
    struct Behavior: Sendable {
        var honorsRange = true
        /// Answers any ranged request with 416.
        var rejectsRange = false
        /// Body bytes sent before the connection is closed (a drop).
        var dropAfter: Int?
        /// Body bytes sent before the server goes quiet with the connection open.
        var stallAfter: Int?
    }

    private struct State {
        var script: [Behavior] = []
        var ranges: [String?] = []
        var connections: [NWConnection] = []
    }

    let body: Data
    private let listener: NWListener
    private let queue = DispatchQueue(label: "RangeServer")
    private let state = Mutex(State())

    init(body: Data) throws {
        self.body = body
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    /// The `Range` header (or nil) of every request so far, in order.
    var ranges: [String?] { state.withLock { $0.ranges } }

    /// The next requests are answered by these behaviors, in order; after them the server behaves.
    func script(_ behaviors: [Behavior]) { state.withLock { $0.script = behaviors } }

    func start() async throws -> URL {
        let resumed = Mutex(false)
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [listener] update in
                let outcome: Result<UInt16, any Error>
                switch update {
                case .ready: outcome = .success(listener.port?.rawValue ?? 0)
                case let .failed(error): outcome = .failure(error)
                default: return
                }
                guard resumed.withLock({ done in defer { done = true }; return !done }) else { return }
                continuation.resume(with: outcome)
            }
            listener.newConnectionHandler = { [self] connection in
                state.withLock { $0.connections.append(connection) }
                connection.start(queue: queue)
                receive(connection, buffer: Data())
            }
            listener.start(queue: queue)
        }
        return URL(string: "http://127.0.0.1:\(port)/")!
    }

    func stop() {
        listener.cancel()
        for connection in state.withLock({ $0.connections }) { connection.cancel() }
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [self] data, _, _, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                respond(connection, head: String(decoding: buffer[..<end.lowerBound], as: UTF8.self))
            } else if error == nil {
                receive(connection, buffer: buffer)
            } else {
                connection.cancel()
            }
        }
    }

    private func respond(_ connection: NWConnection, head: String) {
        let range = head.split(separator: "\r\n").first { $0.lowercased().hasPrefix("range:") }
            .map { $0.dropFirst("range:".count).trimmingCharacters(in: .whitespaces) }
        let behavior = state.withLock { state -> Behavior in
            state.ranges.append(range)
            return state.script.isEmpty ? Behavior() : state.script.removeFirst()
        }
        var start = 0
        var status = "200 OK"
        var extra = ""
        if behavior.honorsRange, let range, range.hasPrefix("bytes="), let from = Int(range.dropFirst(6).dropLast()) {
            if behavior.rejectsRange || from >= body.count {
                send(connection, "HTTP/1.1 416 Range Not Satisfiable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
                return
            }
            start = from
            status = "206 Partial Content"
            extra = "Content-Range: bytes \(from)-\(body.count - 1)/\(body.count)\r\n"
        }
        let payload = body.suffix(from: start)
        let limit = behavior.dropAfter ?? behavior.stallAfter ?? payload.count
        let header = "HTTP/1.1 \(status)\r\nContent-Length: \(payload.count)\r\n\(extra)Connection: close\r\n\r\n"
        send(connection, header, payload.prefix(limit), keepOpen: behavior.stallAfter != nil, dropping: behavior.dropAfter != nil)
    }

    private func send(
        _ connection: NWConnection, _ head: String, _ payload: Data = Data(), keepOpen: Bool = false,
        dropping: Bool = false
    ) {
        // A drop waits a moment before closing, so the client has read what was sent: it is the cut that is under
        // test, not how fast URLSession delivers the bytes ahead of it.
        connection.send(
            content: Data(head.utf8) + payload, contentContext: keepOpen || dropping ? .defaultMessage : .finalMessage,
            isComplete: !(keepOpen || dropping),
            completion: .contentProcessed { [queue] _ in
                if dropping { queue.asyncAfter(deadline: .now() + .milliseconds(100)) { connection.cancel() } }
            })
    }
}

/// Deterministic bytes that no repeated block of them could stand in for.
func fixtureBody(count: Int = 300_000) -> Data {
    Data((0 ..< count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ ($0 >> 8)) })
}

func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// Drains a download: everything it reported, and what it threw.
func drain(_ stream: AsyncThrowingStream<ModelDownloadProgress, any Error>) async
    -> (progress: [ModelDownloadProgress], error: ModelDownloadError?) {
    var progress: [ModelDownloadProgress] = []
    do {
        for try await update in stream { progress.append(update) }
        return (progress, nil)
    } catch {
        return (progress, error as? ModelDownloadError)
    }
}

/// What the store tests share: a local server, a models folder, and the request for the server's file.
protocol ModelDownloadTesting: XCTestCase {
    var directory: URL! { get set }
    var server: RangeServer! { get set }
    var base: URL! { get set }
}

extension ModelDownloadTesting {
    var fileName: String { "fixture-Q8_0.gguf" }

    func startServer() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("oops-model-\(UUID().uuidString)")
        server = try RangeServer(body: fixtureBody())
        base = try await server.start()
    }

    func stopServer() {
        server.stop()
        try? FileManager.default.removeItem(at: directory)
    }

    func request(checksum: String? = nil) -> ModelDownloadRequest {
        ModelDownloadRequest(
            url: base.appendingPathComponent("model"), fileName: fileName,
            byteCount: Int64(server.body.count), sha256: checksum ?? sha256(server.body))
    }

    func store(attempts: Int = 1) -> ModelStore {
        ModelStore(directory: directory, attempts: attempts, retryDelay: .zero)
    }

    var partialURL: URL { ModelDownloadFiles.partialURL(fileName, in: directory) }
    var fileURL: URL { ModelDownloadFiles.fileURL(fileName, in: directory) }
    var receiptURL: URL { ModelDownloadFiles.receiptURL(fileName, in: directory) }
    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    /// Polls until `condition` holds, for what a socket does on its own time.
    func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0 ..< 500 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), "condition never held", file: file, line: line)
    }
}
