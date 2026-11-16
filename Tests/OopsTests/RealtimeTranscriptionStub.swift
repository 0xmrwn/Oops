import Foundation
import Network
import Synchronization

/// A WebSocket server on the loopback that speaks as much of OpenAI's realtime transcription as the client needs.
/// It records every text frame in order and follows a script. No network, no key.
final class RealtimeTranscriptionStub: @unchecked Sendable {
    enum Ending: Sendable {
        /// On commit: `input_audio_buffer.committed`, then the completed transcript.
        case complete(String)
        /// An `error` event right after the session update.
        case errorEvent
        /// Never completes.
        case silent
    }

    struct Script: Sendable {
        var readyAfter: Duration = .zero
        /// One is sent per append received once the session is ready.
        var deltas: [String] = []
        var ending: Ending = .complete("")
    }

    struct Snapshot: Sendable {
        var frames: [String] = []
        var authorization: String?
        /// Appends that arrived before `session.updated` went out.
        var earlyAppends = 0
        var closed = false
    }

    private let script: Script
    private let listener: NWListener
    private let queue = DispatchQueue(label: "realtime-stub")
    private let state = Mutex(Snapshot())
    /// Written by the handshake, which runs before the listener (and so `self`) can be captured.
    private final class Header: Sendable { let value = Mutex<String?>(nil) }
    private let header = Header()
    private let waiters = Mutex<[(test: @Sendable (Snapshot) -> Bool, resume: CheckedContinuation<Void, Never>)]>([])
    // Touched only on `queue`.
    private var ready = false, deltaIndex = 0

    private(set) var port: UInt16 = 0
    var url: URL { URL(string: "ws://127.0.0.1:\(port)/v1/realtime?intent=transcription")! }

    private init(script: Script) throws {
        self.script = script
        let header = header
        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true
        // Set before the listener is made: it takes its own copy of the options.
        websocket.setClientRequestHandler(queue) { _, headers in
            var found: String?
            for (name, value) in headers where name.lowercased() == "authorization" { found = value }
            header.value.withLock { $0 = found }
            return NWProtocolWebSocket.Response(status: .accept, subprotocol: nil)
        }
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
        listener = try NWListener(using: parameters, on: .any)
    }

    static func start(_ script: Script = Script()) async throws -> RealtimeTranscriptionStub {
        let stub = try RealtimeTranscriptionStub(script: script)
        stub.listener.newConnectionHandler = { [weak stub] connection in
            guard let stub else { return }
            connection.start(queue: stub.queue)
            stub.receive(on: connection)
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            stub.listener.stateUpdateHandler = { [weak listener = stub.listener] state in
                switch state {
                case .ready: listener?.stateUpdateHandler = nil; continuation.resume()
                case let .failed(error): listener?.stateUpdateHandler = nil; continuation.resume(throwing: error)
                default: break
                }
            }
            stub.listener.start(queue: stub.queue)
        }
        stub.port = stub.listener.port?.rawValue ?? 0
        return stub
    }

    /// Stops listening and waits until the port is released, so a connection to it is refused.
    func stop() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            listener.stateUpdateHandler = { state in
                if case .cancelled = state { continuation.resume() }
            }
            listener.cancel()
        }
    }

    var snapshot: Snapshot {
        var current = state.withLock { $0 }
        current.authorization = header.value.withLock { $0 }
        return current
    }

    /// Suspends until what the stub has seen satisfies `test`.
    func wait(until test: @escaping @Sendable (Snapshot) -> Bool) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let satisfied = state.withLock { test($0) }
            if satisfied { return continuation.resume() }
            waiters.withLock { $0.append((test: test, resume: continuation)) }
            // A change between the check and the registration would otherwise be missed.
            notify()
        }
    }

    private func notify() {
        let current = snapshot
        let due = waiters.withLock { list -> [CheckedContinuation<Void, Never>] in
            let due = list.filter { $0.test(current) }.map(\.resume)
            list.removeAll { $0.test(current) }
            return due
        }
        due.forEach { $0.resume() }
    }

    // MARK: Connection

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            if error != nil || metadata?.opcode == .close {
                state.withLock { $0.closed = true }
                return notify()
            }
            if let data, metadata?.opcode == .text, let text = String(data: data, encoding: .utf8) { handle(text, on: connection) }
            receive(on: connection)
        }
    }

    private func handle(_ text: String, on connection: NWConnection) {
        let type = ((try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any])?["type"] as? String
        state.withLock { snapshot in
            snapshot.frames.append(text)
            if type == "input_audio_buffer.append", !ready { snapshot.earlyAppends += 1 }
        }
        switch type {
        case "session.update":
            if case .errorEvent = script.ending {
                send(#"{"type":"error","error":{"type":"invalid_request_error","code":"invalid_keyword","message":"nope"}}"#, on: connection)
            } else if script.readyAfter == .zero {
                becomeReady(on: connection)
            } else {
                let delay = Double(script.readyAfter.components.seconds) + Double(script.readyAfter.components.attoseconds) / 1e18
                queue.asyncAfter(deadline: .now() + delay) { self.becomeReady(on: connection) }
            }
        case "input_audio_buffer.append":
            guard ready, deltaIndex < script.deltas.count else { break }
            let delta = script.deltas[deltaIndex]
            deltaIndex += 1
            send(Self.event("conversation.item.input_audio_transcription.delta", ["item_id": "item_1", "delta": delta]), on: connection)
        case "input_audio_buffer.commit":
            guard case let .complete(transcript) = script.ending else { break }
            send(Self.event("input_audio_buffer.committed", ["item_id": "item_1"]), on: connection)
            send(Self.event("conversation.item.input_audio_transcription.completed", ["item_id": "item_1", "transcript": transcript]), on: connection)
        default: break
        }
        notify()
    }

    private func becomeReady(on connection: NWConnection) {
        ready = true
        send(#"{"type":"session.updated","session":{"type":"transcription"}}"#, on: connection)
    }

    private static func event(_ type: String, _ fields: [String: String]) -> String {
        let object = fields.merging(["type": type]) { $1 }
        return String(decoding: (try? JSONSerialization.data(withJSONObject: object)) ?? Data(), as: UTF8.self)
    }

    private func send(_ text: String, on connection: NWConnection) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        connection.send(content: Data(text.utf8), contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }
}
