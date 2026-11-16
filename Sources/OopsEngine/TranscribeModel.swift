import CTranscribe
import Foundation
import OopsCore

/// A loaded model, freed with its last reference: what the engine holds between uses.
protocol LoadedModel: AnyObject {
    func run(_ samples: [Float], language: String?, vocabulary: VocabularyDelivery?) throws(SpeechEngineError) -> String
    /// Starts streaming on the model's session, ending any stream still open there.
    func beginStream(_ context: SpeechModelLiveContext, language: String?) throws(SpeechEngineError)
    /// Feeds the open stream; the words so far when they changed.
    func feedStream(_ samples: [Float]) throws(SpeechEngineError) -> LiveWords?
    /// Ends the open stream without finishing it, so the session can run or stream again.
    func resetStream()
}

/// Stand-ins that never stream need none of it.
extension LoadedModel {
    func beginStream(_ context: SpeechModelLiveContext, language: String?) throws(SpeechEngineError) {
        throw .streamingUnsupported
    }

    func feedStream(_ samples: [Float]) throws(SpeechEngineError) -> LiveWords? { nil }
    func resetStream() {}
}

/// One transcribe.cpp session over the C API, which owns the model it opened. A few calls are all Oops needs;
/// upstream's Swift wrapper would add a hundred kilobytes of diarization and options for them.
final class TranscribeModel: LoadedModel {
    /// Metal keeps a loaded model's buffers resident, waking the CPU about 166 times a second, until this many
    /// seconds after its last run (about 1.2 times as long in practice). Shorter than the idle release, so the
    /// wake-ups stop while the model is still loaded and the next use within the window pays nothing.
    static let keepAliveSeconds = 10
    /// ggml reads it once, when the first model loads; set before that, whatever the environment had.
    private static let keepAlive: Void = { setenv("GGML_METAL_RESIDENCY_KEEP_ALIVE_S", String(keepAliveSeconds), 1) }()

    let session: OpaquePointer

    init(url: URL) throws(SpeechEngineError) {
        guard FileManager.default.fileExists(atPath: url.path) else { throw .noModelFile }
        _ = Self.keepAlive
        var session: OpaquePointer?
        let status = transcribe_open(url.path, nil, nil, &session)
        if status == TRANSCRIBE_ERR_FILE_NOT_FOUND { throw .noModelFile }
        guard status == TRANSCRIBE_OK, let session else { throw .unusableModel(Self.reason(status)) }
        self.session = session
    }

    deinit { transcribe_session_free(session) }

    func run(_ samples: [Float], language: String?, vocabulary: VocabularyDelivery?) throws(SpeechEngineError) -> String {
        guard !samples.isEmpty else { return "" }
        guard let count = Int32(exactly: samples.count) else { throw .transcriptionFailed("recording too long") }
        let run = RunOptions(language: language, vocabulary: vocabulary, model: transcribe_get_model(session))
        // Without a language or a vocabulary, the defaults (nil params) are what Oops always ran.
        let status = samples.withUnsafeBufferPointer { buffer in
            guard run.isNeeded else { return transcribe_run(session, buffer.baseAddress, count, nil) }
            return run.withParams { transcribe_run(session, buffer.baseAddress, count, $0) }
        }
        guard status == TRANSCRIBE_OK else { throw .transcriptionFailed(Self.reason(status)) }
        guard let text = transcribe_full_text(session) else { return "" }
        return String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func reason(_ status: transcribe_status) -> String {
        String(cString: transcribe_status_string(Int32(status.rawValue)))
    }
}
