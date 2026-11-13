import Foundation

/// A feature that picks its own model from the switched-on ones.
public enum ModelFeature: String, CaseIterable, Codable, Sendable {
    case fix, dictate, actions

    /// Where the feature's choice is kept. Fix keeps the key it has always used, so existing choices load
    /// unchanged; Actions has no choice yet.
    public var preferenceKey: String {
        switch self {
        case .fix: "modelSelection"
        case .dictate: "dictateSelection"
        case .actions: "actionsSelection"
        }
    }

    /// Whether a model can serve the feature.
    public func accepts(_ capabilities: ModelCapabilities) -> Bool {
        self == .dictate ? capabilities.voice : capabilities.text
    }
}

/// A speech model Dictate can use: one Oops manages on this Mac, or one a provider serves.
public enum VoiceModelReference: Codable, Equatable, Hashable, Sendable {
    /// An id from Oops's own speech model catalog.
    case local(String)
    case provider(ModelSelection.Choice)
}

/// What Dictate needs to know of a model's languages. `SpeechModel` from the catalog provides it.
public protocol SpeechLanguageSupport {
    func supports(_ code: String) -> Bool
    /// A one-language model shows its language as fixed text rather than a choice.
    var isSingleLanguage: Bool { get }
}

/// Dictate's speech model and language.
public struct DictateSelection: Codable, Equatable, Sendable {
    public var model: VoiceModelReference?
    /// A BCP-47 code; nil is Automatic (the model detects the language).
    public var language: String?

    public init(model: VoiceModelReference? = nil, language: String? = nil) { self.model = model; self.language = language }

    /// Switching model keeps the chosen language when the new model supports it, otherwise it becomes
    /// Automatic. A one-language model follows the same rule: its own language is kept, any other becomes
    /// Automatic, which on that model can only mean its language. `languages` nil (a provider model whose
    /// languages aren't known) keeps it: such models are taken to transcribe any language.
    public mutating func switchModel(to model: VoiceModelReference?, languages: any SpeechLanguageSupport?) {
        self.model = model
        if let language, let languages, !languages.supports(language) { self.language = nil }
    }
}
