import Foundation
import OopsCore
import Synchronization

/// A model store the test drives: each download's progress, end and failure come from the test, and files are
/// "installed" by name. Nothing touches the network or the disk.
final class FakeModelStore: ModelDownloading {
    private struct State {
        var streams: [String: AsyncThrowingStream<ModelDownloadProgress, any Error>.Continuation] = [:]
        var installed: Set<String> = []
        var downloads: [String] = []
        var cancelled: [String] = []
        var deleteFails = false
    }

    private let state = Mutex(State())

    init(installed: Set<String> = []) { state.withLock { $0.installed = installed } }

    var downloads: [String] { state.withLock { $0.downloads } }
    var cancelled: [String] { state.withLock { $0.cancelled } }
    func failDeletes() { state.withLock { $0.deleteFails = true } }

    static func url(_ fileName: String) -> URL { URL(fileURLWithPath: "/models/\(fileName)") }

    func download(_ request: ModelDownloadRequest) -> AsyncThrowingStream<ModelDownloadProgress, any Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: ModelDownloadProgress.self)
        state.withLock { $0.streams[request.fileName] = continuation; $0.downloads.append(request.fileName) }
        return stream
    }

    func send(_ fileName: String, _ phase: ModelDownloadProgress.Phase, fraction: Double) {
        let progress = ModelDownloadProgress(phase: phase, receivedBytes: Int64(fraction * 1000), expectedBytes: 1000)
        _ = state.withLock { $0.streams[fileName] }?.yield(progress)
    }

    func install(_ fileName: String) {
        let continuation = state.withLock { $0.installed.insert(fileName); return $0.streams.removeValue(forKey: fileName) }
        continuation?.finish()
    }

    func fail(_ fileName: String, _ error: ModelDownloadError) {
        state.withLock { $0.streams.removeValue(forKey: fileName) }?.finish(throwing: error)
    }

    func cancel(fileName: String) async {
        state.withLock { $0.cancelled.append(fileName) }
        fail(fileName, .cancelled)
    }

    func delete(fileName: String) async throws {
        if state.withLock({ $0.deleteFails }) { throw ModelDownloadError.disk("busy") }
        _ = state.withLock { $0.installed.remove(fileName) }
    }

    func isInstalled(_ request: ModelDownloadRequest) async -> Bool { state.withLock { $0.installed.contains(request.fileName) } }

    func installedFileURL(for request: ModelDownloadRequest) async -> URL? {
        await isInstalled(request) ? Self.url(request.fileName) : nil
    }
}

/// Waits for main-actor work the test started (a download's task, a driver's loop) to catch up.
@MainActor func eventually(_ condition: () -> Bool, seconds: Double = 2) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while !condition() {
        guard ContinuousClock.now < deadline else { return false }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return true
}
