import Foundation
import OopsCore

extension DictationSession {
    /// Ends the recording at `released`, transcribes it and writes the text at the caret. No speech, an
    /// empty transcript and an insert the person cancelled write nothing and say nothing.
    func process(released: CaptureInstant?) async -> Ending {
        // The recording is ended first, whatever else is missing: nothing may leave the microphone recording.
        guard let recorder, let engine, case let .samples(samples) = await recorder.stop(at: released), let model = loadedModel else { return .done }
        let text: String
        do {
            // A load or warm-up that failed gets one more try, now that a recording needs it.
            do { try await loading?.value } catch { try await engine.load(model: model) }
            text = try await engine.transcribe(samples)
        } catch {
            // Loaded afresh by the next start.
            loadedModel = nil; loading = nil
            return .failed(error as? SpeechEngineError == .noModelFile ? .noModel : .transcription)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .done }
        switch await insert(trimmed) {
        case .inserted, .unconfirmed, .refused(.cancelled), .refused(.empty): return .done
        case .refused: return .failed(.cannotWrite)
        }
    }
}
