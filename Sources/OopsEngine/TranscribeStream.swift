import Foundation
import OopsCore
import Synchronization

/// One dictation streaming through `TranscribeEngine`. It keeps every sample appended, so `finish` runs the one-shot
/// over the whole recording even if a newer stream took the model's session meanwhile.
final class TranscribeStream: SpeechStream {
    let words: AsyncStream<LiveWords>
    private let continuation: AsyncStream<LiveWords>.Continuation
    private let engine: TranscribeEngine
    private let id: Int
    private let language: String?
    private let vocabulary: VocabularyDelivery?
    /// The samples so far; nil once `finish` or `cancel` ended the stream, so later appends are dropped.
    private let samples = Mutex<[Float]?>([])

    init(engine: TranscribeEngine, id: Int, language: String?, vocabulary: VocabularyDelivery?) {
        (words, continuation) = AsyncStream.makeStream(of: LiveWords.self)
        self.engine = engine
        self.id = id
        self.language = language
        self.vocabulary = vocabulary
    }

    func append(_ new: [Float]) async {
        guard !new.isEmpty else { return }
        let taken = samples.withLock { samples in
            guard samples != nil else { return false }
            samples?.append(contentsOf: new)
            return true
        }
        if taken { await engine.feed(id, samples: new) }
    }

    func finish() async throws -> String {
        defer { continuation.finish() }
        guard let recorded = end() else { return "" }
        return try await engine.finishStream(id, samples: recorded, language: language, vocabulary: vocabulary)
    }

    func cancel() async {
        continuation.finish()
        guard end() != nil else { return }
        await engine.cancelStream(id)
    }

    /// The engine's words for this stream, as they change.
    func publish(_ live: LiveWords) {
        continuation.yield(live)
    }

    /// The samples, once: nil when the stream had already ended.
    private func end() -> [Float]? {
        samples.withLock { samples in
            defer { samples = nil }
            return samples
        }
    }
}
