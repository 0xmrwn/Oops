import Foundation

/// Speech to text. Only values cross it, so the app never sees an engine's types and the local engine could move
/// to a helper process. A local engine releases its model by itself once it's idle and reloads it on the next use,
/// so callers never manage its memory; a hosted engine holds no connection between dictations.
public protocol SpeechEngine: Sendable {
    /// Loads the model at `url`, replacing any model already loaded. A hosted engine has nothing to load.
    func load(model url: URL) async throws
    /// Loads the model and runs it once, in the background after launch, so the first dictation never waits for
    /// the GPU's one-time setup (seconds on the first launch of each new build). A hosted engine does nothing.
    func warmUp(model url: URL) async throws
    /// One shot over 16 kHz mono samples. `language` is a hint in the engine's own terms (a local model's
    /// `SpeechModel.runtimeLanguageHint(for:)`, an ISO 639-1 code for OpenAI); nil lets the model detect it, or use
    /// its only language. `vocabulary` is the user's list as this engine takes it (`VocabularyRouting`): a Parakeet
    /// bias or a context prompt reaches a local engine, OpenAI keywords the OpenAI engine; anything else sends nothing.
    func transcribe(_ samples: [Float], language: String?, vocabulary: VocabularyDelivery?) async throws -> String
    /// Starts one dictation's streaming session over the loaded model (local) or a new connection (hosted), taking
    /// `language` and `vocabulary` as `transcribe` does. Returns at once: a hosted engine connects in the background
    /// and holds the audio appended meanwhile. Throws `SpeechEngineError.streamingUnsupported` for a model that can't
    /// stream, so the dictation goes on without live words; `.notLoaded` before any `load`.
    func startStream(language: String?, vocabulary: VocabularyDelivery?) async throws -> any SpeechStream
    /// Frees the model and what it holds on the GPU.
    func unload() async
}

public extension SpeechEngine {
    /// Engines that can't stream (and test fakes) need nothing more.
    func startStream(language: String?, vocabulary: VocabularyDelivery?) async throws -> any SpeechStream {
        throw SpeechEngineError.streamingUnsupported
    }
}

/// One dictation streaming through an engine: its audio is appended as it is recorded, its words so far are
/// published as they change, and `finish` gives the text to write. Used by one caller at a time, in order:
/// `append`… then exactly one of `finish` or `cancel`.
public protocol SpeechStream: AnyObject, Sendable {
    /// Each change of the words so far, newest last. Finishes after `finish` returns or throws, or after `cancel`.
    /// For display only: never written.
    var words: AsyncStream<LiveWords> { get }
    /// Appends 16 kHz mono samples that follow the ones appended before. Returns once they are taken (queued for a
    /// connection that isn't ready yet, or fed to the model); never throws: a stream that failed keeps taking audio
    /// and reports the failure from `finish`.
    func append(_ samples: [Float]) async
    /// The recording is over and all of it was appended: the text to write, untrimmed. A local stream runs a one-shot
    /// pass over every sample appended (streamed text can differ from it, and lacks the closing punctuation); a
    /// hosted stream commits the turn once and returns the completed transcript. Throws `SpeechEngineError`.
    func finish() async throws -> String
    /// Abandons the dictation: nothing more is sent or committed, and a connection closes. Safe to call twice and
    /// after `finish`.
    func cancel() async
}

/// The words heard so far while a dictation streams.
public struct LiveWords: Equatable, Sendable {
    /// Text the engine will not revise.
    public var stable: String
    /// Text after `stable` that later audio may still change.
    public var changing: String

    public init(stable: String, changing: String = "") {
        self.stable = stable
        self.changing = changing
    }

    /// Both parts as one line: runs of whitespace (newlines included) become one space, ends trimmed. The engines
    /// give each part with its own leading spaces, so the parts join as they are.
    public var text: String {
        (stable + changing).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    public var isEmpty: Bool { text.isEmpty }
}

public enum SpeechEngineError: Error, Equatable, Sendable {
    /// No file at the model's path.
    case noModelFile
    /// The file is there but isn't a model the engine can load (truncated, another format, unsupported); the
    /// engine's own reason.
    case unusableModel(String)
    case transcriptionFailed(String)
    /// `transcribe` or `startStream` before any `load`, or after `unload`.
    case notLoaded
    /// The model offers no live words: the catalog marks it one-shot, or the runtime refused to stream it.
    case streamingUnsupported
    /// A hosted engine couldn't connect, reported an error, or sent no transcript in time. The reason names the
    /// failure (`connection`, `error <code>`, `timeout`) and never carries a key or what was said.
    case hostedFailed(String)
}
