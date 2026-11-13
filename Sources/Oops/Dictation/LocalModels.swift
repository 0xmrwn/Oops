import Foundation
import Observation
import OopsCore

/// The speech models Oops can download, and where each one stands on this Mac. Nothing is fetched unless
/// `download` is called, which only a Download button does.
@Observable @MainActor final class LocalModels {
    enum State: Equatable {
        case notInstalled
        /// The fraction received.
        case downloading(Double)
        /// Every byte is in; the checksum is being checked.
        case verifying
        case installed
        case failed(String)
    }

    /// The app's, over `Application Support/oops/Models`. Created when dictation first asks for it.
    static let shared = LocalModels(store: ModelStore(directory: ModelStoreLocation.url))

    let models: [SpeechModel]
    private(set) var states: [String: State] = [:]
    @ObservationIgnored private let store: any ModelDownloading
    @ObservationIgnored private var files: [String: URL] = [:]
    @ObservationIgnored private var running: Set<String> = []
    /// Cancelled, still winding down; and of those, pressed Download again meanwhile.
    @ObservationIgnored private var stopping: Set<String> = []
    @ObservationIgnored private var restarting: Set<String> = []

    init(store: any ModelDownloading, models: [SpeechModel] = SpeechModelCatalog.models) {
        self.store = store
        self.models = models
    }

    func state(_ model: SpeechModel) -> State { states[model.id] ?? .notInstalled }

    var installed: [SpeechModel] { models.filter { states[$0.id] == .installed } }

    func isInstalled(_ id: String) -> Bool { states[id] == .installed }

    /// The installed file of the model with this id, nil when it isn't installed.
    func fileURL(_ id: String) -> URL? { isInstalled(id) ? files[id] : nil }

    /// Reads what is on disk. A download in progress, and a failure the person hasn't acted on, keep their state.
    func refresh() async {
        for model in models where !running.contains(model.id) {
            let url = await store.installedFileURL(for: model.artifact.downloadRequest)
            guard !running.contains(model.id) else { continue }
            files[model.id] = url
            if url != nil {
                states[model.id] = .installed
            } else if case .failed = state(model) {} else {
                states[model.id] = .notInstalled
            }
        }
    }

    /// Starts or resumes the download; the store keeps a cancelled one's partial file. Pressed again while a
    /// cancelled download is still winding down, it starts once that one has ended.
    func download(_ model: SpeechModel) {
        guard !running.contains(model.id) else {
            guard stopping.contains(model.id) else { return }
            restarting.insert(model.id)
            states[model.id] = .downloading(0)
            return
        }
        running.insert(model.id)
        states[model.id] = .downloading(0)
        Task {
            let ended = await follow(model)
            running.remove(model.id)
            stopping.remove(model.id)
            if restarting.remove(model.id) != nil, ended == .notInstalled { return download(model) }
            states[model.id] = ended
        }
    }

    /// Shows the download's progress on the row, and returns where it ended.
    private func follow(_ model: SpeechModel) async -> State {
        let request = model.artifact.downloadRequest
        do {
            for try await progress in store.download(request) where !stopping.contains(model.id) {
                switch progress.phase {
                case .downloading: states[model.id] = .downloading(progress.fraction)
                case .verifying: states[model.id] = .verifying
                case .installed: break
                }
            }
            let url = await store.installedFileURL(for: request)
            files[model.id] = url
            return url == nil ? .failed(Self.message(ModelDownloadError.checksumMismatch)) : .installed
        } catch {
            return error as? ModelDownloadError == .cancelled ? .notInstalled : .failed(Self.message(error))
        }
    }

    func cancel(_ model: SpeechModel) {
        guard running.contains(model.id) else { return }
        // The row shows Download at once; the download's end confirms it.
        stopping.insert(model.id)
        restarting.remove(model.id)
        states[model.id] = .notInstalled
        Task { await store.cancel(fileName: model.artifact.fileName) }
    }

    /// Removes the file. Returns false when it couldn't be, with the reason on the row.
    @discardableResult func delete(_ model: SpeechModel) async -> Bool {
        do {
            try await store.delete(fileName: model.artifact.fileName)
            files[model.id] = nil
            states[model.id] = .notInstalled
            return true
        } catch {
            states[model.id] = .failed("Couldn’t delete the model.")
            return false
        }
    }

    /// A short line for the row: a connection's own reason can run long.
    static func message(_ error: any Error) -> String {
        switch error as? ModelDownloadError {
        case .network?: "Couldn’t connect. Try again."
        case .disk?: "Couldn’t save the model."
        case let known?: known.errorDescription ?? "Download failed."
        case nil: error.localizedDescription
        }
    }

    #if DEBUG
    /// Settings snapshots show each state without a download.
    func seed(_ id: String, _ state: State, file: URL? = nil) {
        states[id] = state
        files[id] = file
    }
    #endif
}
