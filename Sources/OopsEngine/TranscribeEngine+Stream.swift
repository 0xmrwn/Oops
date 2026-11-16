import Foundation
import OopsCore

/// Live words: one stream at a time on the model's session, fed on the engine's queue as the audio is appended.
/// The written text never comes from the stream: `finishStream` runs the one-shot over the stream's own samples.
extension TranscribeEngine {
    /// Audio is fed in encoder frames (80 ms), so the words can change after each.
    static let feedSlice = 1280

    // Async, unlike the engine's other calls: a synchronous one loses to the protocol's async default (which refuses to
    // stream) when called on the engine itself from async code.
    public func startStream(language: String?, vocabulary: VocabularyDelivery?) async throws(SpeechEngineError) -> any SpeechStream {
        guard let modelURL else { throw .notLoaded }
        // A file the catalog doesn't pin (a debug override) has no known context to stream with.
        guard let context = SpeechModelCatalog.model(atPath: modelURL.path)?.liveContext else { throw .streamingUnsupported }
        defer { releaseWhenIdle() }
        let model = try reopen(modelURL)
        // A stream still open is replaced; its handle keeps its samples, so its `finish` still writes.
        if stream != nil {
            model.resetStream()
            stream = nil
        }
        try model.beginStream(context, language: language)
        streams += 1
        let handle = TranscribeStream(engine: self, id: streams, language: language, vocabulary: vocabulary)
        stream = OpenStream(id: streams, handle: handle)
        return handle
    }

    func feed(_ id: Int, samples: [Float]) {
        guard let open = stream, open.id == id, !open.failed, let model else { return }
        releaseWhenIdle()
        var start = samples.startIndex
        while start < samples.endIndex {
            let end = min(start + Self.feedSlice, samples.endIndex)
            do {
                if let words = try model.feedStream(Array(samples[start ..< end])) { open.handle.publish(words) }
            } catch {
                // Only the live words stop: the written text comes from the one-shot at `finish`.
                stream?.failed = true
                return
            }
            start = end
        }
    }

    func finishStream(_ id: Int, samples: [Float], language: String?,
                      vocabulary: VocabularyDelivery?) throws(SpeechEngineError) -> String {
        cancelStream(id)
        guard !samples.isEmpty else { return "" }
        return try transcribe(samples, language: language, vocabulary: vocabulary)
    }

    func cancelStream(_ id: Int) {
        guard stream?.id == id else { return }
        model?.resetStream()
        stream = nil
        releaseWhenIdle()
    }
}
