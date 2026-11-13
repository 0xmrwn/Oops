import Foundation
import OopsCore

/// One dictation's live words: the stream its engine opened for it, the pump that hands the stream the recording as
/// it grows, and the task that shows the words while the dictation's turn holds the drop. The words are only ever
/// shown: the text written comes from the stream's `finish`, at the release.
@MainActor final class LiveDictation {
    /// The session's turn at the press: words from a dictation whose turn has passed never show.
    let turn: Int
    /// Streams through a hosted engine, which nothing else can transcribe.
    let hosted: Bool
    /// The stream once the engine opened it; nil when it can't stream (a model that only transcribes once).
    let starting: Task<any SpeechStream?, Never>
    var pump: Task<Void, Never>?
    var wordsTask: Task<Void, Never>?
    /// How many of the recording's samples the stream has.
    var sent = 0
    /// How many times the words changed, and how long after the press they first did: for the log.
    var updates = 0
    var firstWordsAt: Duration?
    let began = ContinuousClock.now
    /// The recording ended: no pump starts any more, and the rest of the clip is appended at the release.
    private(set) var released = false
    /// None of this dictation's words show any more.
    private(set) var ended = false

    init(turn: Int, hosted: Bool, starting: Task<any SpeechStream?, Never>) {
        self.turn = turn; self.hosted = hosted; self.starting = starting
    }

    /// Stops the pump and waits out an append it was making, so the stream's audio stays in recording order.
    func release() async {
        released = true
        pump?.cancel()
        await pump?.value
    }

    /// No more words show; those on screen stay until the session clears them.
    func stopWords() {
        ended = true
        wordsTask?.cancel()
    }

    /// Abandons the dictation: nothing more is sent, nothing is committed. The stream is cancelled once it's there,
    /// without holding the caller up while a model still loads.
    func cancel() {
        released = true
        stopWords()
        pump?.cancel()
        starting.cancel()
        Task { [starting] in await starting.value?.cancel() }
    }
}

extension DictationSession {
    /// How often the pump hands the stream what was recorded since: an encoder frame of the local models.
    static let pumpInterval: Duration = .milliseconds(80)

    /// Opens the recording's stream beside it, with the language and vocabulary read at the press. A local model
    /// streams once it's loaded, so its stream may open after the release; the first pump sends everything recorded
    /// so far, and the release appends the rest, so a late start loses nothing.
    func beginLive(engine: any SpeechEngine, hosted: Bool) {
        guard let recorder else { return }
        let language = language, vocabulary = hosted ? plan.vocabulary : plan.engineVocabulary, loading = hosted ? nil : loading
        let starting = Task<any SpeechStream?, Never> {
            _ = try? await loading?.value
            do { return try await engine.startStream(language: language, vocabulary: vocabulary) } catch {
                Self.log.notice("live unavailable error=\(String(describing: error), privacy: .public)")
                return nil
            }
        }
        let live = LiveDictation(turn: turn, hosted: hosted, starting: starting)
        self.live = live
        Task { [weak self] in
            guard let stream = await starting.value, let self, !live.ended else { return }
            if !live.released { live.pump = Self.pump(live, into: stream, from: recorder) }
            live.wordsTask = Task { [weak self] in
                for await words in stream.words {
                    guard let self, !live.ended, turn == live.turn else { break }
                    if live.updates == 0 { live.firstWordsAt = .now - live.began }
                    live.updates += 1
                    drop.showWords(words)
                }
            }
        }
    }

    private static func pump(_ live: LiveDictation, into stream: any SpeechStream, from recorder: DictationRecorder) -> Task<Void, Never> {
        Task {
            while !Task.isCancelled {
                let fresh = await recorder.recorded(from: live.sent)
                if !fresh.isEmpty {
                    live.sent += fresh.count
                    await stream.append(fresh)
                }
                try? await Task.sleep(for: pumpInterval)
            }
        }
    }

    /// The recording under way is dropped: its stream is cancelled and its words show no more.
    func endLive() {
        live?.cancel()
        live = nil
    }

    /// The text of `live`'s stream over the whole of `samples`, the released clip: what the pump didn't send is
    /// appended, then the stream finishes. Nil when there is no stream and a local model transcribes the clip once
    /// instead, as it also does when the stream heard audio past the clip's end (a release handled late). Throws the
    /// stream's failure, and for a hosted engine that couldn't even start.
    func finishLive(_ live: LiveDictation, samples: [Float]) async throws -> String? {
        guard let stream = await live.starting.value else {
            if live.hosted { throw SpeechEngineError.hostedFailed("connection") }
            return nil
        }
        if !live.hosted, live.sent > samples.count {
            await stream.cancel()
            return nil
        }
        if live.sent < samples.count {
            await stream.append(Array(samples[live.sent...]))
            live.sent = samples.count
        }
        return try await stream.finish()
    }
}
