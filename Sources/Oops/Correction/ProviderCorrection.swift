import Foundation
import OopsCore

/// The provider work and clear-cache identity of one press, independent of the editor and capsule.
@MainActor final class ProviderCorrection {
    struct Identity: Equatable {
        let choice: ModelSelection.Choice?
        let kind: Provider.Kind?
        let endpoint: String?
        let settings: ModelSelection.Settings
        let tier: String?
        let keyRevision: Int
    }

    private weak var store: ProviderStore?
    private let revision: Int
    let model: DebugAttempt.Model?
    let modelName: String?
    let promptVersion: String
    let instructions: String
    private var backend: Result<any CorrectionBackend, Error>?
    private var operation: Task<String, Error>?
    private var cancelled = false
    private var completed = false
    private(set) var preparation: Task<Void, Never>?

    init(store: ProviderStore) {
        self.store = store
        revision = store.correctionRevision
        model = store.debugModel; modelName = store.currentModel?.name
        promptVersion = CorrectionPolicy.promptVersion; instructions = CorrectionPolicy.instructions
        store.activeCorrection?.cancel()
        store.activeCorrection = self
        let backend = Result { try store.backend() }
        self.backend = backend
        preparation = Task {
            guard !Task.isCancelled, let backend = try? backend.get() else { return }
            await backend.prepare()
        }
    }

    func checkCurrent() throws {
        try Task.checkCancellation()
        guard !cancelled, let store, store.correctionRevision == revision,
              CorrectionPolicy.promptVersion == promptVersion else { throw CancellationError() }
    }

    func complete(_ text: String) async throws -> String {
        try checkCurrent()
        guard let backend else { throw CancellationError() }
        let selected = try backend.get()
        let task = Task { try Task.checkCancellation(); return try await selected.complete(text) }
        operation = task
        defer { operation = nil }
        return try await withTaskCancellationHandler {
            do {
                let raw = try await task.value
                try checkCurrent()
                completed = true
                return raw
            } catch {
                try checkCurrent()
                throw error
            }
        } onCancel: { task.cancel() }
    }

    func cancel() { end(discardBackend: true) }
    func finish() { end(discardBackend: !completed) }

    private func end(discardBackend: Bool) {
        cancelled = true; preparation?.cancel(); operation?.cancel(); backend = nil
        store?.endCorrection(self, discardBackend: discardBackend)
    }

    func isClear(app: String?, source: String) throws -> Bool {
        try checkCurrent()
        return store?.lastClear == clearKey(app: app, source: source)
    }

    func rememberClear(app: String?, source: String) throws {
        try checkCurrent()
        store?.lastClear = clearKey(app: app, source: source)
    }

    private func clearKey(app: String?, source: String) -> String {
        ["\(revision)", promptVersion, app ?? "", source].joined(separator: "\u{0}")
    }
}
