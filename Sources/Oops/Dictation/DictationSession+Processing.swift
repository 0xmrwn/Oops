import AppKit
import OopsCore

extension DictationSession {
    /// Ends the recording at `released`, transcribes it (through `live`'s stream when it has one) and writes the
    /// text at the caret. No speech, an empty transcript and an insert the person cancelled write nothing and say
    /// nothing. Any other transcript is kept as the last one, written or not.
    func process(released: CaptureInstant?, live: LiveDictation? = nil) async -> Ending {
        guard let recorder else { return .done }
        // The stream takes nothing more from the recording: the rest of the clip follows in order.
        await live?.release()
        // The recording is ended first, whatever else is missing: nothing may leave the microphone recording.
        let samples: [Float]
        switch await recorder.stop(at: released) {
        case .samples(let recorded): samples = recorded
        case .discarded(let reason):
            // Nothing to transcribe, so a hosted stream never commits.
            live?.cancel()
            Self.log.notice("discarded reason=\(String(describing: reason), privacy: .public)")
            return .done
        }
        let hosted = live?.hosted == true, model = loadedModel
        guard hosted || (engine != nil && model != nil) else { live?.cancel(); return .done }
        let seconds = Double(samples.count) / Double(DictationCapture.sampleRate), began = ContinuousClock.now
        Self.log.notice("recorded seconds=\(seconds, format: .fixed(precision: 2), privacy: .public) peak_dbfs=\(Self.peak(samples), format: .fixed(precision: 1), privacy: .public) level_max=\(self.loudness.loudest, format: .fixed(precision: 2), privacy: .public) level_mean=\(self.loudness.mean, format: .fixed(precision: 2), privacy: .public)")
        let text: String
        do {
            if let live, let streamed = try await finishLive(live, samples: samples) {
                text = streamed
            } else if let engine, let model {
                // A load or warm-up that failed gets one more try, now that a recording needs it.
                do { try await loading?.value } catch { try await engine.load(model: model) }
                text = try await engine.transcribe(samples, language: language, vocabulary: plan.engineVocabulary)
            } else {
                throw SpeechEngineError.notLoaded
            }
        } catch {
            live?.stopWords()
            // Loaded afresh by the next start; a hosted engine has nothing loaded.
            if !hosted { loadedModel = nil; loading = nil }
            Self.log.notice("transcription failed error=\(String(describing: error), privacy: .public)")
            return .failed(!hosted && error as? SpeechEngineError == .noModelFile ? .noModel : .transcription)
        }
        live?.stopWords()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        Self.log.notice("transcribed length=\(trimmed.utf16.count, privacy: .public) ms=\(DebugLog.milliseconds(since: began), privacy: .public)")
        if let live {
            let first = live.firstWordsAt.map { String(Int($0 / .milliseconds(1))) } ?? "none"
            Self.log.notice("live engine=\(live.hosted ? "openai" : "local", privacy: .public) updates=\(live.updates, privacy: .public) first_ms=\(first, privacy: .public)")
        }
        guard !trimmed.isEmpty else { return .done }
        let polished = await polish(trimmed)
        guard !polished.isEmpty else { return .done }
        // Gone before the one write, so the words never show twice; a newer dictation's words are its own.
        if let live, live.turn == turn { drop.showWords(nil) }
        let outcome = await insert(polished)
        // A cancelled insert leaves the last transcript alone, as Hex's cancelled jobs do.
        if outcome != .refused(.cancelled) { lastTranscript = polished }
        // Clean up's button replaces the text later, so only a field that read the text back offers it.
        if outcome == .inserted, plan.mode == .button { return .offer(polished) }
        return Self.ending(outcome)
    }

    /// What an insert's outcome shows: nothing once written, Copy where no text field had focus, and why
    /// otherwise.
    static func ending(_ outcome: InsertOutcome) -> Ending {
        switch outcome {
        case .inserted, .unconfirmed, .refused(.cancelled), .refused(.empty): .done
        case .refused(.noEditor): .kept
        case .refused(.secureField): .failed(.secureField)
        case .refused(.appDenied): .failed(.appDenied)
        case .refused(.appTurnedOff): .failed(.turnedOff)
        case .refused: .failed(.cannotWrite)
        }
    }

    /// The kept drop's Copy: the last transcript goes on the clipboard and stays there, as Hex's copy-only
    /// dictation leaves it, and the drop says so.
    func copyLast() {
        guard let lastTranscript else { return }
        copy(lastTranscript)
        drop.show(.copied)
    }

    /// The clipboard (the general one unless a test names another), as an ordinary entry the person copied.
    static func copyToClipboard(_ text: String, on board: NSPasteboard = .general) {
        board.clearContents()
        board.setString(text, forType: .string)
    }

    /// The loudest sample, in dBFS: enough to tell a dead input from a quiet room in the log.
    private static func peak(_ samples: [Float]) -> Float {
        let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
        return peak > 0 ? 20 * log10(peak) : -.infinity
    }
}
