import OopsCore
#if OOPS_PREVIEW
import OopsEngine
#endif

/// Where the app gets its speech engine: transcribe.cpp in a preview build (OOPS_PREVIEW=1), none otherwise, so a
/// distributed build neither links nor names it. The only place in the app that sees OopsEngine.
enum DictationEngineProvider {
    #if OOPS_PREVIEW
    /// One for the app: one model in memory, one queue for its work.
    private static let shared = TranscribeEngine()
    static func engine() -> (any SpeechEngine)? { shared }
    /// Before the process exits: a model still loaded then makes ggml abort in its static destructors. False when
    /// a run kept the model past the wait.
    static func shutDown() -> Bool { shared.shutDown() }
    #else
    static func engine() -> (any SpeechEngine)? { nil }
    static func shutDown() -> Bool { true }
    #endif
}
