import CTranscribe
import Foundation
import OopsCore

/// Live words over the session's streaming API. Only the words shown while speaking come from here: the stream is
/// never finalized, since the written text is a one-shot run over the whole recording.
extension TranscribeModel {
    func beginStream(_ context: SpeechModelLiveContext, language: String?) throws(SpeechEngineError) {
        let model = transcribe_get_model(session)
        var capabilities = transcribe_capabilities()
        transcribe_capabilities_init(&capabilities)
        let options = StreamOptions(context: context)
        guard transcribe_model_get_capabilities(model, &capabilities) == TRANSCRIBE_OK, capabilities.supports_streaming,
              transcribe_model_accepts_ext_kind(model, TRANSCRIBE_EXT_SLOT_STREAM, options.kind)
        else { throw .streamingUnsupported }
        // A stream left open, finished or failed would refuse the next begin or run.
        if transcribe_stream_get_state(session) != TRANSCRIBE_STREAM_IDLE { transcribe_stream_reset(session) }
        // The vocabulary only matters for the written text, which the one-shot run gives.
        let run = RunOptions(language: language, vocabulary: nil, model: model)
        let status = run.withParams { params in options.withParams { transcribe_stream_begin(session, params, $0) } }
        guard status == TRANSCRIBE_OK else {
            // A refused begin can leave the stream FAILED; the one-shot at the end still needs the session.
            transcribe_stream_reset(session)
            if status == TRANSCRIBE_ERR_NOT_IMPLEMENTED { throw .streamingUnsupported }
            throw .transcriptionFailed(Self.reason(status))
        }
    }

    func feedStream(_ samples: [Float]) throws(SpeechEngineError) -> LiveWords? {
        guard !samples.isEmpty, let count = Int32(exactly: samples.count) else { return nil }
        var update = transcribe_stream_update()
        transcribe_stream_update_init(&update)
        let status = samples.withUnsafeBufferPointer { transcribe_stream_feed(session, $0.baseAddress, count, &update) }
        guard status == TRANSCRIBE_OK else { throw .transcriptionFailed(Self.reason(status)) }
        guard update.committed_changed || update.tentative_changed else { return nil }
        var text = transcribe_stream_text()
        transcribe_stream_text_init(&text)
        guard transcribe_stream_get_text(session, &text) == TRANSCRIBE_OK else { return nil }
        return LiveWords(stable: Self.string(text.committed_text, text.committed_text_bytes),
                         changing: Self.string(text.tentative_text, text.tentative_text_bytes))
    }

    func resetStream() { transcribe_stream_reset(session) }

    /// The views aren't promised to end in a NUL: their byte counts bound them.
    private static func string(_ bytes: UnsafePointer<CChar>?, _ count: UInt64) -> String {
        guard let bytes, count > 0 else { return "" }
        return String(decoding: UnsafeRawBufferPointer(start: bytes, count: Int(count)), as: UTF8.self)
    }
}

/// The stream's params and the family extension for a live context, in the C API's terms.
struct StreamOptions {
    let context: SpeechModelLiveContext

    var kind: UInt32 {
        switch context {
        case .chunked: TRANSCRIBE_EXT_KIND_PARAKEET_BUFFERED_STREAM
        case .cacheAware: TRANSCRIBE_EXT_KIND_PARAKEET_STREAM
        }
    }

    /// `body` with params pointing at this context's extension, valid only inside it.
    func withParams<Result>(_ body: (UnsafePointer<transcribe_stream_params>) -> Result) -> Result {
        switch context {
        case let .chunked(chunk, lookahead):
            var ext = transcribe_parakeet_buffered_stream_ext()
            transcribe_parakeet_buffered_stream_ext_init(&ext)
            ext.chunk_ms = Int32(chunk)
            ext.right_ms = Int32(lookahead)
            return Self.params(family: &ext, body)
        case let .cacheAware(lookahead):
            var ext = transcribe_parakeet_stream_ext()
            transcribe_parakeet_stream_ext_init(&ext)
            ext.att_context_right = Int32(lookahead)
            return Self.params(family: &ext, body)
        }
    }

    private static func params<Result>(family: inout some Any, _ body: (UnsafePointer<transcribe_stream_params>) -> Result) -> Result {
        var params = transcribe_stream_params()
        transcribe_stream_params_init(&params)
        params.commit_policy = TRANSCRIBE_STREAM_COMMIT_AUTO
        return withUnsafePointer(to: &family) { ext in
            // The extension's first field is the generic header the params point at.
            params.family = UnsafeRawPointer(ext).assumingMemoryBound(to: transcribe_ext.self)
            return withUnsafePointer(to: &params) { body($0) }
        }
    }
}
