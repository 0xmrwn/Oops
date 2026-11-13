import Dispatch
import Foundation
import OopsCore

/// Dictation's engine: transcribe.cpp on this Mac's GPU. Work runs on the engine's own serial queue, never on the
/// main actor or the cooperative pool: a first load in a new build blocks for seconds while Metal compiles.
/// The model is released `IdleRelease.after` its last use and reloaded on the next (about 0.1 s).
public actor TranscribeEngine: SpeechEngine {
    public struct IdleRelease: Sendable {
        public var after: Duration
        /// Returns once `after` has passed, or early when cancelled; tests pass their own.
        public var sleep: @Sendable (Duration) async -> Void

        public init(after: Duration, sleep: @escaping @Sendable (Duration) async -> Void = { _ = try? await Task.sleep(for: $0) }) {
            self.after = after
            self.sleep = sleep
        }

        /// GPU memory back within 30 s of the last dictation; the CPU's wake-ups stop sooner, at the keep-alive.
        public static let standard = IdleRelease(after: .seconds(20))
    }

    private nonisolated let queue = DispatchSerialQueue(label: "dev.0xmrwn.oops.engine", qos: .userInitiated)
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private let idleRelease: IdleRelease
    private let open: @Sendable (URL) throws(SpeechEngineError) -> any LoadedModel
    /// Kept across an idle release, so the next use can reload; forgotten by `unload`.
    private var modelURL: URL?
    private var model: any LoadedModel?
    /// The pending release, and which use it follows: a later use makes it stale.
    private(set) var idleTask: Task<Void, Never>?
    private var uses = 0

    public init(idleRelease: IdleRelease = .standard) {
        self.init(idleRelease: idleRelease) { url throws(SpeechEngineError) in try TranscribeModel(url: url) }
    }

    init(idleRelease: IdleRelease, open: @escaping @Sendable (URL) throws(SpeechEngineError) -> any LoadedModel) {
        self.idleRelease = idleRelease
        self.open = open
    }

    var holdsModel: Bool { model != nil }

    public func load(model url: URL) throws(SpeechEngineError) {
        unload()
        model = try open(url)
        modelURL = url
        releaseWhenIdle()
    }

    public func warmUp(model url: URL) throws(SpeechEngineError) {
        try load(model: url)
        // A second of silence: whatever it says (or refuses), the first run's setup is done.
        _ = try? model?.run([Float](repeating: 0, count: 16000))
    }

    public func transcribe(_ samples: [Float]) throws(SpeechEngineError) -> String {
        guard let modelURL else { throw .notLoaded }
        defer { releaseWhenIdle() }
        let model: any LoadedModel
        if let held = self.model { model = held } else { model = try open(modelURL) }
        self.model = model
        return try model.run(samples)
    }

    public func unload() {
        idleTask?.cancel()
        idleTask = nil
        model = nil
        modelURL = nil
    }

    private func releaseWhenIdle() {
        idleTask?.cancel()
        uses += 1
        let use = uses, idleRelease = idleRelease
        idleTask = Task { [weak self] in
            await idleRelease.sleep(idleRelease.after)
            await self?.release(after: use)
        }
    }

    private func release(after use: Int) {
        guard use == uses, !Task.isCancelled else { return }
        model = nil
        idleTask = nil
    }
}
