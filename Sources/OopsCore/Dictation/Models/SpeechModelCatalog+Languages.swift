import Foundation

// A port of the language rules of Hex's `ModelDefinition` at v3.4.0 (MIT, github.com/anomalyco/hex), from
// `src/transcription/models.rs`. See THIRD_PARTY_NOTICES.md.

/// A model and language chosen together, for a selection or a keyboard mapping.
public struct SpeechModelSelection: Sendable, Equatable {
    public let modelID: String
    public let language: String

    public init(modelID: String, language: String) {
        self.modelID = modelID
        self.language = language
    }
}

public enum SpeechModelSelectionError: Error, Equatable, Sendable {
    case unsupportedLanguage(String)
    case unknownModel(String)
    case modelDoesNotSupport(model: String, language: String)
}

public extension SpeechModel {
    /// The languages Settings offers for this model, in `SpeechLanguage.listed` order, Auto first when the model
    /// detects the language, then the other languages the model declares.
    var languageChoices: [String] {
        let listed = SpeechLanguage.listed.map(\.code).filter { supports(language: $0) }
        guard case .anyKnown = languages else {
            return listed + languages.codes.filter { !SpeechLanguage.isListed($0) }
        }
        return listed
    }

    /// The language a switch to this model falls back to when it does not support the selected one: English when
    /// it can, else its first.
    var defaultLanguage: String {
        supports(language: "en") ? "en" : (languages.codes.first ?? "en")
    }

    /// `code` when this model supports it, else its default language, so a model switch always yields a valid
    /// selection.
    func language(for code: String) -> String {
        supports(language: code) ? code : defaultLanguage
    }
}

public extension SpeechModelCatalog {
    /// Hex's `validate`: the selection's language is one Hex knows, its model exists and supports it.
    @discardableResult
    static func validate(_ selection: SpeechModelSelection) throws(SpeechModelSelectionError) -> SpeechModel {
        guard SpeechLanguage.isKnown(selection.language) else {
            throw .unsupportedLanguage(selection.language)
        }
        guard let model = model(id: selection.modelID) else { throw .unknownModel(selection.modelID) }
        guard model.supports(language: selection.language) else {
            throw .modelDoesNotSupport(model: model.name, language: SpeechLanguage.name(of: selection.language))
        }
        return model
    }
}
