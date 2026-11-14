import Foundation

/// One dictation over one realtime transcription connection. Audio appended before the session is ready waits; the
/// turn is committed once, when the recording ends, and the completed transcript is the text to write. A failure
/// at any point is kept and thrown by `finish`: the recording itself never notices. Nothing here logs the request
/// (it carries the key), the audio or the words.
public actor RealtimeTranscriptionClient: SpeechStream {
    public nonisolated let words: AsyncStream<LiveWords>

    private let request: URLRequest, transport: any RealtimeTransport
    private let languages: [String], keywords: [String], timeout: Duration
    private let continuation: AsyncStream<LiveWords>.Continuation
    private var encoder = RealtimeAudioEncoder()

    private var socket: any RealtimeSocket?
    private var connection: Task<Void, Never>?, deadline: Task<Void, Never>?
    private var closed = false, ready = false, draining = false
    /// Audio chunks waiting for `session.updated`, in order.
    private var pending: [String] = []
    /// Frames to send, in order: one pump drains it, so concurrent appends can't reorder what reaches the socket.
    private var outbox: [String] = []
    private var finishing = false, commitSent = false
    private var committedItem: String?
    private var heard = ""
    private var outcome: Result<String, SpeechEngineError>?
    private var waiter: CheckedContinuation<String, any Error>?

    public init(request: URLRequest, transport: any RealtimeTransport, languages: [String], keywords: [String],
                timeout: Duration = .seconds(10)) {
        self.request = request; self.transport = transport; self.languages = languages
        self.keywords = keywords; self.timeout = timeout
        (words, continuation) = AsyncStream.makeStream(of: LiveWords.self)
    }

    /// Connects in the background; returns at once.
    public func start() {
        guard connection == nil, !closed else { return }
        connection = Task { await run() }
    }

    public func append(_ samples: [Float]) {
        guard !finishing, outcome == nil else { return }
        for chunk in encoder.encode(samples) { send(audio: chunk) }
    }

    public func finish() async throws -> String {
        guard !finishing else { throw SpeechEngineError.hostedFailed("finished") }
        finishing = true
        if outcome == nil {
            if let rest = encoder.flush() { send(audio: rest) }
            commitWhenReady()
            deadline = Task {
                try? await Task.sleep(for: timeout)
                expire()
            }
        }
        defer { close() }
        if let outcome { return try outcome.get() }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }

    public func cancel() {
        guard !closed else { return }
        conclude(.failure(.hostedFailed("cancelled")))
    }

    // MARK: Connection

    private func run() async {
        do {
            let socket = try await transport.connect(request)
            guard !closed else { return socket.close() }
            self.socket = socket
            enqueue(RealtimeTranscription.sessionUpdate(languages: languages, keywords: keywords))
            while !closed { handle(RealtimeTranscription.ServerEvent.parse(try await socket.receive())) }
        } catch {
            fail(.hostedFailed("connection"))
        }
    }

    private func handle(_ event: RealtimeTranscription.ServerEvent) {
        switch event {
        case .ready:
            guard !ready else { return }
            ready = true
            for chunk in pending { enqueue(RealtimeTranscription.append(chunk)) }
            pending = []
            commitWhenReady()
        case let .committed(item): committedItem = item
        case let .delta(_, text):
            heard += text
            continuation.yield(LiveWords(stable: heard))
        case let .completed(item, transcript):
            if commitSent, mine(item) { conclude(.success(transcript)) }
        case let .failed(item):
            if commitSent, mine(item) { fail(.hostedFailed("transcription")) }
        case let .error(code): fail(.hostedFailed("error \(code ?? "unknown")"))
        case .other: break
        }
    }

    /// With one turn per connection, an item is ours unless a commit named another; none counts before the commit.
    private func mine(_ item: String) -> Bool { committedItem == nil || item.isEmpty || item == committedItem }

    // MARK: Sending

    private func send(audio chunk: String) {
        if ready { enqueue(RealtimeTranscription.append(chunk)) } else { pending.append(chunk) }
    }

    private func commitWhenReady() {
        guard ready, finishing, !commitSent else { return }
        commitSent = true
        enqueue(RealtimeTranscription.commit)
    }

    private func enqueue(_ frame: String) {
        guard !closed else { return }
        outbox.append(frame)
        guard !draining, let socket else { return }
        draining = true
        Task { await pump(socket) }
    }

    private func pump(_ socket: any RealtimeSocket) async {
        while !closed, !outbox.isEmpty {
            do { try await socket.send(outbox.removeFirst()) } catch {
                draining = false
                return fail(.hostedFailed("connection"))
            }
        }
        draining = false
    }

    // MARK: Ending

    private func expire() { fail(.hostedFailed("timeout")) }

    private func fail(_ error: SpeechEngineError) { conclude(.failure(error)) }

    /// The first outcome stands and ends the connection. A dictation still recording keeps it for `finish`; one
    /// waiting gets it now.
    private func conclude(_ result: Result<String, SpeechEngineError>) {
        guard outcome == nil else { return }
        outcome = result
        continuation.finish()
        if let waiter {
            self.waiter = nil
            waiter.resume(with: result.mapError { $0 as any Error })
        }
        close()
    }

    /// Releases the socket and everything waiting on it. Safe to repeat.
    private func close() {
        closed = true
        connection?.cancel(); deadline?.cancel()
        socket?.close(); socket = nil
        outbox = []; pending = []
        continuation.finish()
    }
}
