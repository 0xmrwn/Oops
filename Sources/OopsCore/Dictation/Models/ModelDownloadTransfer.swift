import Foundation
import Synchronization

// A port of `piece` in Hex's `src/net/download.rs` (MIT, github.com/anomalyco/hex) at v3.4.0: one ranged request
// appended to the partial file, with the server's answer read as `ModelDownloadPlan.reply` does. Hex asks for 8 MB
// pieces because its HTTP client cannot stall-detect a long body; URLSession's per-packet timeout does, so this
// streams the rest of the file in one request. See THIRD_PARTY_NOTICES.md.

/// One request streamed into the partial file as it arrives. Each chunk is written on the session's serial
/// delegate queue, so a slow disk slows the reading instead of piling bytes up in memory.
final class ModelDownloadTransfer: NSObject, URLSessionDataDelegate, Sendable {
    enum Outcome: Equatable {
        /// The partial file now holds every byte.
        case finished
        /// The server has no such range: the partial file must go and the fetch start over.
        case discardPartial
    }

    private struct State {
        var continuation: CheckedContinuation<Outcome, any Error>?
        var task: URLSessionDataTask?
        var handle: FileHandle?
        var written: Int64
        var failure: ModelDownloadError?
        var discard = false
        var cancelled = false
        var lastReport = ContinuousClock.now
    }

    /// At most this often, so a progress bar redraws at a sane rate whatever the link speed.
    private static let reportInterval: Duration = .milliseconds(100)

    private let request: ModelDownloadRequest
    private let partial: URL
    private let offset: Int64
    private let report: @Sendable (Int64) -> Void
    private let state: Mutex<State>

    private init(request: ModelDownloadRequest, partial: URL, offset: Int64, report: @escaping @Sendable (Int64) -> Void) {
        self.request = request
        self.partial = partial
        self.offset = offset
        self.report = report
        state = Mutex(State(written: offset))
    }

    /// Fetches `request` from `offset` on into `partial`. `report` hears the file's length as it grows.
    static func run(
        _ request: ModelDownloadRequest, into partial: URL, from offset: Int64, session: URLSession,
        report: @escaping @Sendable (Int64) -> Void
    ) async throws -> Outcome {
        let transfer = ModelDownloadTransfer(request: request, partial: partial, offset: offset, report: report)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in transfer.start(continuation, session: session) }
        } onCancel: {
            transfer.cancel()
        }
    }

    private func start(_ continuation: CheckedContinuation<Outcome, any Error>, session: URLSession) {
        var urlRequest = URLRequest(url: request.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        if let range = ModelDownloadPlan.rangeHeader(from: offset) { urlRequest.setValue(range, forHTTPHeaderField: "Range") }
        // A compressed body would not line up with the byte ranges.
        urlRequest.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let task = session.dataTask(with: urlRequest)
        task.delegate = self
        let alreadyCancelled = state.withLock { state in
            state.continuation = continuation
            state.task = task
            return state.cancelled
        }
        if alreadyCancelled { task.cancel() }
        task.resume()
    }

    private func cancel() {
        let task = state.withLock { state in
            state.cancelled = true
            return state.task
        }
        task?.cancel()
    }

    func urlSession(
        _: URLSession, dataTask _: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let http = response as? HTTPURLResponse
        let reply = ModelDownloadPlan.reply(
            status: http?.statusCode ?? 0, contentRange: http?.value(forHTTPHeaderField: "Content-Range"), offset: offset)
        switch reply {
        case .append: open(truncating: false, completionHandler)
        case .restart: open(truncating: true, completionHandler)
        case .discardPartial:
            state.withLock { $0.discard = true }
            completionHandler(.cancel)
        case let .failure(error):
            state.withLock { $0.failure = error }
            completionHandler(.cancel)
        }
    }

    private func open(truncating: Bool, _ completionHandler: (URLSession.ResponseDisposition) -> Void) {
        do {
            if truncating || !FileManager.default.fileExists(atPath: partial.path) {
                guard FileManager.default.createFile(atPath: partial.path, contents: nil) else {
                    throw ModelDownloadError.disk("\(partial.lastPathComponent) cannot be created")
                }
            }
            let handle = try FileHandle(forWritingTo: partial)
            let length = truncating ? 0 : try handle.seekToEnd()
            guard Int64(length) == (truncating ? 0 : offset) else { throw ModelDownloadError.unexpectedRange }
            state.withLock { state in
                state.handle = handle
                state.written = Int64(length)
            }
            completionHandler(.allow)
        } catch {
            state.withLock { $0.failure = error as? ModelDownloadError ?? .disk(error.localizedDescription) }
            completionHandler(.cancel)
        }
    }

    func urlSession(_: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let (written, due, failed) = state.withLock { state -> (Int64, Bool, Bool) in
            guard state.failure == nil, let handle = state.handle else { return (state.written, false, true) }
            if state.written + Int64(data.count) > request.byteCount {
                state.failure = .tooMuchData(expected: request.byteCount)
                return (state.written, false, true)
            }
            do {
                try handle.write(contentsOf: data)
            } catch {
                state.failure = .disk(error.localizedDescription)
                return (state.written, false, true)
            }
            state.written += Int64(data.count)
            let now = ContinuousClock.now
            let due = now - state.lastReport >= Self.reportInterval
            if due { state.lastReport = now }
            return (state.written, due, false)
        }
        if failed { dataTask.cancel() } else if due { report(written) }
    }

    func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: any Error?) {
        let (continuation, failure, discard, cancelled, written) = state.withLock { state in
            try? state.handle?.synchronize()
            try? state.handle?.close()
            state.handle = nil
            let continuation = state.continuation
            state.continuation = nil
            return (continuation, state.failure, state.discard, state.cancelled, state.written)
        }
        report(written)
        if let failure {
            continuation?.resume(throwing: failure)
        } else if discard {
            continuation?.resume(returning: .discardPartial)
        } else if cancelled || (error as? URLError)?.code == .cancelled {
            continuation?.resume(throwing: ModelDownloadError.cancelled)
        } else if let error {
            continuation?.resume(throwing: ModelDownloadError.network(error.localizedDescription))
        } else if written < request.byteCount {
            continuation?.resume(throwing: ModelDownloadError.network("the connection closed early"))
        } else {
            continuation?.resume(returning: .finished)
        }
    }
}
