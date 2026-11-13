import CTranscribe
import Foundation
import OopsCore

/// A loaded model, freed with its last reference: what the engine holds between uses.
protocol LoadedModel: AnyObject {
    func run(_ samples: [Float], language: String?) throws(SpeechEngineError) -> String
}

/// One transcribe.cpp session over the C API, which owns the model it opened. Three calls are all Oops needs;
/// upstream's Swift wrapper would add a hundred kilobytes of streaming, diarization and options for them.
final class TranscribeModel: LoadedModel {
    /// Metal keeps a loaded model's buffers resident, waking the CPU about 166 times a second, until this many
    /// seconds after its last run (about 1.2 times as long in practice). Shorter than the idle release, so the
    /// wake-ups stop while the model is still loaded and the next use within the window pays nothing.
    static let keepAliveSeconds = 10
    /// ggml reads it once, when the first model loads; set before that, whatever the environment had.
    private static let keepAlive: Void = { setenv("GGML_METAL_RESIDENCY_KEEP_ALIVE_S", String(keepAliveSeconds), 1) }()

    private let session: OpaquePointer

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

    func run(_ samples: [Float], language: String?) throws(SpeechEngineError) -> String {
        guard !samples.isEmpty else { return "" }
        guard let count = Int32(exactly: samples.count) else { throw .transcriptionFailed("recording too long") }
        // Without a language, the defaults (nil params) are what Oops always ran; the library copies the string.
        let status = samples.withUnsafeBufferPointer { buffer in
            guard let language else { return transcribe_run(session, buffer.baseAddress, count, nil) }
            return language.withCString { code in
                var params = transcribe_run_params()
                transcribe_run_params_init(&params)
                params.language = code
                return transcribe_run(session, buffer.baseAddress, count, &params)
            }
        }
        guard status == TRANSCRIBE_OK else { throw .transcriptionFailed(Self.reason(status)) }
        guard let text = transcribe_full_text(session) else { return "" }
        return String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func reason(_ status: transcribe_status) -> String {
        String(cString: transcribe_status_string(Int32(status.rawValue)))
    }
}
