import OopsCore
import OopsEngine

/// Where the app gets its speech engine, transcribe.cpp. The only place in the app that sees OopsEngine.
enum DictationEngineProvider {
    /// One for the app: one model in memory, one queue for its work.
    private static let shared = TranscribeEngine()
    static func engine() -> any SpeechEngine { shared }
    /// Before the process exits: a model still loaded then makes ggml abort in its static destructors. False when
    /// a run kept the model past the wait.
    static func shutDown() -> Bool { shared.shutDown() }
}
