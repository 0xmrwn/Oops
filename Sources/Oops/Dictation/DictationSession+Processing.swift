import Foundation
import OopsCore

extension DictationSession {
    /// Ends the recording at `released`, transcribes it and writes the text at the caret. No speech, an
    /// empty transcript and an insert the person cancelled write nothing and say nothing.
    func process(released: CaptureInstant?) async -> Ending {
        guard let recorder, let engine else { return .done }
        // The recording is ended first, whatever else is missing: nothing may leave the microphone recording.
        let samples: [Float]
        switch await recorder.stop(at: released) {
        case .samples(let recorded): samples = recorded
        case .discarded(let reason):
            Self.log.notice("discarded reason=\(String(describing: reason), privacy: .public)")
            return .done
        }
        guard let model = loadedModel else { return .done }
        let seconds = Double(samples.count) / Double(DictationCapture.sampleRate), began = ContinuousClock.now
        Self.log.notice("recorded seconds=\(seconds, format: .fixed(precision: 2), privacy: .public) peak_dbfs=\(Self.peak(samples), format: .fixed(precision: 1), privacy: .public)")
        let text: String
        do {
            // A load or warm-up that failed gets one more try, now that a recording needs it.
            do { try await loading?.value } catch { try await engine.load(model: model) }
            text = try await engine.transcribe(samples, language: language)
        } catch {
            // Loaded afresh by the next start.
            loadedModel = nil; loading = nil
            Self.log.notice("transcription failed error=\(String(describing: error), privacy: .public)")
            return .failed(error as? SpeechEngineError == .noModelFile ? .noModel : .transcription)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        Self.log.notice("transcribed length=\(trimmed.utf16.count, privacy: .public) ms=\(DebugLog.milliseconds(since: began), privacy: .public)")
        guard !trimmed.isEmpty else { return .done }
        switch await insert(trimmed) {
        case .inserted, .unconfirmed, .refused(.cancelled), .refused(.empty): return .done
        case .refused: return .failed(.cannotWrite)
        }
    }

    /// The loudest sample, in dBFS: enough to tell a dead input from a quiet room in the log.
    private static func peak(_ samples: [Float]) -> Float {
        let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
        return peak > 0 ? 20 * log10(peak) : -.infinity
    }
}
