import Foundation

// A port of `download_artifact` and its helpers in Hex's `src/transcription/models.rs` (MIT,
// github.com/anomalyco/hex) at v3.4.0: resume a `.partial` file, verify the size and checksum, move it into place
// and write the receipt. Hex's cross-process download lock is not ported: one app owns this folder. See
// THIRD_PARTY_NOTICES.md.

/// What the UI needs of a model store, so it can be tested with a fake. Nothing here starts a download by itself.
public protocol ModelDownloading: Sendable {
    /// Downloads, verifies and installs the file. Progress is throttled; the stream ends when the file is
    /// installed, or throws a `ModelDownloadError`. Dropping the stream stops the transfer, keeping the partial file.
    func download(_ request: ModelDownloadRequest) -> AsyncThrowingStream<ModelDownloadProgress, any Error>
    /// Stops a running download, keeping its partial file for a later resume.
    func cancel(fileName: String) async
    /// Removes the file, its partial and its receipt, stopping a running download first.
    func delete(fileName: String) async throws
    func isInstalled(_ request: ModelDownloadRequest) async -> Bool
    func installedFileURL(for request: ModelDownloadRequest) async -> URL?
}

/// Speech-model files in one folder, downloaded on request only.
public actor ModelStore: ModelDownloading {
    public let directory: URL
    private let session: URLSession
    private let attempts: Int
    private let retryDelay: Duration
    private var active: [String: (id: UUID, task: Task<Void, Never>)] = [:]

    /// `attempts` is how many times one `download` asks the server before giving up on a dropped connection,
    /// waiting `retryDelay` between; each attempt resumes where the file ends.
    public init(
        directory: URL, session: URLSession = URLSession(configuration: .ephemeral),
        attempts: Int = 3, retryDelay: Duration = .seconds(2)
    ) {
        self.directory = directory
        self.session = session
        self.attempts = max(1, attempts)
        self.retryDelay = retryDelay
    }

    public func isInstalled(_ request: ModelDownloadRequest) -> Bool {
        ModelDownloadFiles.isInstalled(request, in: directory)
    }

    public func installedFileURL(for request: ModelDownloadRequest) -> URL? {
        isInstalled(request) ? ModelDownloadFiles.fileURL(request.fileName, in: directory) : nil
    }

    public func cancel(fileName: String) {
        active[fileName]?.task.cancel()
    }

    public func delete(fileName: String) async throws {
        if let running = active[fileName] {
            running.task.cancel()
            await running.task.value
        }
        try ModelDownloadFiles.removeAll(fileName, in: directory)
    }

    public nonisolated func download(_ request: ModelDownloadRequest) -> AsyncThrowingStream<ModelDownloadProgress, any Error> {
        // Only the newest progress matters to a bar, so a slow reader never holds the transfer back.
        let (stream, continuation) = AsyncThrowingStream.makeStream(
            of: ModelDownloadProgress.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        continuation.onTermination = { [weak self] reason in
            guard case .cancelled = reason else { return }
            Task { await self?.cancel(id: id, fileName: request.fileName) }
        }
        Task { await self.begin(request, id: id, continuation) }
        return stream
    }

    private func cancel(id: UUID, fileName: String) {
        if active[fileName]?.id == id { cancel(fileName: fileName) }
    }

    private func begin(
        _ request: ModelDownloadRequest, id: UUID,
        _ continuation: AsyncThrowingStream<ModelDownloadProgress, any Error>.Continuation
    ) {
        guard active[request.fileName] == nil else {
            continuation.finish(throwing: ModelDownloadError.alreadyDownloading)
            return
        }
        let job = Job(
            request: request, directory: directory, session: session, attempts: attempts, retryDelay: retryDelay,
            continuation: continuation)
        let task = Task {
            let failure = await job.run()
            ended(request.fileName, id: id)
            continuation.finish(throwing: failure)
        }
        active[request.fileName] = (id, task)
    }

    private func ended(_ fileName: String, id: UUID) {
        if active[fileName]?.id == id { active[fileName] = nil }
    }
}

/// One download from start to installed, off the store's actor so that hashing a few gigabytes never blocks it.
private struct Job: Sendable {
    let request: ModelDownloadRequest
    let directory: URL
    let session: URLSession
    let attempts: Int
    let retryDelay: Duration
    let continuation: AsyncThrowingStream<ModelDownloadProgress, any Error>.Continuation

    /// `nil` when the file is installed.
    @concurrent func run() async -> ModelDownloadError? {
        do {
            try await perform()
            return nil
        } catch let error as ModelDownloadError {
            return error
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .disk(error.localizedDescription)
        }
    }

    private func emit(_ phase: ModelDownloadProgress.Phase, _ received: Int64) {
        continuation.yield(
            ModelDownloadProgress(phase: phase, receivedBytes: received, expectedBytes: request.byteCount))
    }

    private func perform() async throws {
        let destination = ModelDownloadFiles.fileURL(request.fileName, in: directory)
        let partial = ModelDownloadFiles.partialURL(request.fileName, in: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if ModelDownloadFiles.isInstalled(request, in: directory) {
            emit(.installed, request.byteCount)
            return
        }
        // A whole file that has no receipt yet (copied in, or the receipt lost) is checked rather than fetched again.
        if ModelDownloadFiles.size(of: destination) == request.byteCount {
            emit(.verifying, request.byteCount)
            if (try? ModelDownloadVerifier.verify(destination, against: request)) != nil {
                try ModelDownloadFiles.writeReceipt(for: request, in: directory)
                emit(.installed, request.byteCount)
                return
            }
        }

        var failures = 0
        var discards = 0
        fetching: while true {
            try Task.checkCancellation()
            switch ModelDownloadPlan.start(partialBytes: ModelDownloadFiles.size(of: partial), expected: request.byteCount) {
            case .verifyPartial: break fetching
            case .discardPartial: try? FileManager.default.removeItem(at: partial)
            case let .fetch(offset):
                emit(.downloading, offset)
                do {
                    let outcome = try await ModelDownloadTransfer.run(
                        request, into: partial, from: offset, session: session
                    ) { emit(.downloading, $0) }
                    if outcome == .discardPartial {
                        discards += 1
                        guard discards < 2 else { throw ModelDownloadError.badStatus(416) }
                        try? FileManager.default.removeItem(at: partial)
                    }
                } catch ModelDownloadError.network(let reason) {
                    failures += 1
                    guard failures < attempts else { throw ModelDownloadError.network(reason) }
                    try await Task.sleep(for: retryDelay)
                }
            }
        }

        emit(.verifying, request.byteCount)
        do {
            try ModelDownloadVerifier.verify(partial, against: request)
        } catch let error as ModelDownloadError {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: partial, to: destination)
        try ModelDownloadFiles.writeReceipt(for: request, in: directory)
        emit(.installed, request.byteCount)
    }
}
