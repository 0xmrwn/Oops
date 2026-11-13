import Foundation

/// Speech to text on this Mac. Only values cross it, so the app never sees the engine's types and the engine
/// could move to a helper process. An engine releases its model by itself once it's idle and reloads it on the
/// next use, so callers never manage its memory.
public protocol SpeechEngine: Sendable {
    /// Loads the model at `url`, replacing any model already loaded.
    func load(model url: URL) async throws
    /// Loads the model and runs it once, in the background after launch, so the first dictation never waits for
    /// the GPU's one-time setup (seconds on the first launch of each new build).
    func warmUp(model url: URL) async throws
    /// One shot over 16 kHz mono samples. `language` is a hint in the model's own code
    /// (`SpeechModel.runtimeLanguageHint(for:)`); nil lets the model detect it, or use its only language.
    func transcribe(_ samples: [Float], language: String?) async throws -> String
    /// Frees the model and what it holds on the GPU.
    func unload() async
}

public enum SpeechEngineError: Error, Equatable, Sendable {
    /// No file at the model's path.
    case noModelFile
    /// The file is there but isn't a model the engine can load (truncated, another format, unsupported); the
    /// engine's own reason.
    case unusableModel(String)
    case transcriptionFailed(String)
    /// `transcribe` before any `load`, or after `unload`.
    case notLoaded
}
