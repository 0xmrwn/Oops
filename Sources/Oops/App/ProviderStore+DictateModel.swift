import Foundation
import OopsCore

/// One entry of Dictate's model menu: an installed model on this Mac.
struct DictateModelOption: Identifiable, Equatable {
    let reference: VoiceModelReference
    let name: String
    /// Returns words while audio still arrives. A model that can't only transcribes once the recording ends.
    let streams: Bool
    /// The Language menu's codes, `SpeechLanguage.auto` first when the model detects the language.
    let languages: [String]
    /// What Automatic (no language chosen) means on this model.
    let automatic: String

    var id: VoiceModelReference { reference }
    var isSingleLanguage: Bool { languages.count == 1 }

    init(_ model: SpeechModel) {
        reference = .local(model.id); name = model.name; streams = model.streams
        languages = model.languageChoices; automatic = model.automaticLanguage
    }
}

extension ProviderStore {
    /// Dictate's model menu: the installed models. A provider's voice model has no way to transcribe yet, so
    /// it isn't offered.
    func dictateOptions(_ local: LocalModels) -> [DictateModelOption] {
        local.installed.map(DictateModelOption.init)
    }

    /// The model dictation uses: the selection, or the first installed model in place of a provider's, which
    /// can't transcribe yet.
    private func dictateModel(_ local: LocalModels) -> VoiceModelReference? {
        guard case .provider? = dictateSelection.model else { return dictateSelection.model }
        return local.installed.first.map { .local($0.id) }
    }

    /// The model in use when it can be used now: installed.
    func dictateOption(_ local: LocalModels) -> DictateModelOption? {
        guard let model = dictateModel(local) else { return nil }
        return dictateOptions(local).first { $0.reference == model }
    }

    /// The language shown and used: the chosen one when the model has it, else what Automatic means on it.
    func dictateLanguage(for option: DictateModelOption) -> String {
        dictateSelection.language.flatMap { option.languages.contains($0) ? $0 : nil } ?? option.automatic
    }

    /// A model picked from the menu; the language follows `DictateSelection.switchModel`.
    func chooseDictateModel(_ reference: VoiceModelReference) {
        guard case .local(let id) = reference else { return selectDictate(reference, languages: nil) }
        selectDictate(reference, languages: SpeechModelCatalog.model(id: id))
    }

    func chooseDictateLanguage(_ code: String) {
        selectDictate(language: code == SpeechLanguage.auto ? nil : code)
    }

    /// A keyboard mapping's model and language, as they are: the mapping was made for this pair.
    func applyKeyboardChoice(_ choice: KeyboardModelChoice) {
        selectDictate(.local(choice.modelID), languages: nil)
        chooseDictateLanguage(choice.language)
    }

    /// The file the engine loads: `override` (the debug default) when set, else the selected model's installed
    /// file. Nil, dictation fails with "No speech model".
    func dictationModelPath(_ local: LocalModels, override: String?) -> String? {
        if let override, !override.isEmpty { return override }
        guard case .local(let id)? = dictateModel(local) else { return nil }
        return local.fileURL(id)?.path
    }

    /// The selected language in the engine's terms; nil under Automatic, with the debug override, or for a model
    /// that takes no hint.
    func dictationLanguageHint(_ local: LocalModels, override: String?) -> String? {
        guard override?.isEmpty != false, case .local(let id)? = dictateModel(local),
              let model = SpeechModelCatalog.model(id: id), local.isInstalled(id) else { return nil }
        return model.runtimeLanguageHint(for: dictateLanguage(for: DictateModelOption(model)))
    }

    /// Deletes an installed model; Dictate forgets it when it was the one selected.
    func deleteLocalModel(_ model: SpeechModel, from local: LocalModels) async {
        guard await local.delete(model), dictateSelection.model == .local(model.id) else { return }
        selectDictate(nil, languages: nil)
        selectDictate(language: nil)
    }
}
