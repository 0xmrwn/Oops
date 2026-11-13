import Foundation

extension SpeechModel: SpeechLanguageSupport {
    public func supports(_ code: String) -> Bool { supports(language: code) }
}

public extension SpeechModel {
    /// The language Dictate uses when its selection names none (Automatic): detection when the model has it,
    /// else the model's default.
    var automaticLanguage: String { supportsLanguageDetection ? SpeechLanguage.auto : defaultLanguage }

    /// What the capability resolver knows of a catalog model: speech to text only.
    var capabilities: ModelCapabilities {
        ModelCapabilities(text: false, voice: true, streaming: streams, languages: languages.codes, source: .catalog)
    }
}

public extension SpeechModelCatalog {
    /// Step 1 of `CapabilityResolver` for the models Oops manages on this Mac (`kind` nil); providers' models are
    /// left to the later steps.
    static let capabilityLookup: CapabilityResolver.CatalogLookup = { kind, modelID in
        kind == nil ? model(id: modelID)?.capabilities : nil
    }
}
