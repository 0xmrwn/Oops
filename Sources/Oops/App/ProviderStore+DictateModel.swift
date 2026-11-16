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

    /// OpenAI's transcription takes any language by its two-letter code, or detects it.
    init(openAI reference: VoiceModelReference) {
        self.reference = reference; name = "GPT-Live-Transcribe"; streams = true
        languages = [SpeechLanguage.auto] + SpeechLanguage.known.filter { $0.count == 2 }; automatic = SpeechLanguage.auto
    }
}

extension ProviderStore {
    /// Dictate's model menu: the installed models, then OpenAI's live transcription when an OpenAI key is set up.
    func dictateOptions(_ local: LocalModels) -> [DictateModelOption] {
        local.installed.map(DictateModelOption.init) + (openAIDictateReference.map { [DictateModelOption(openAI: $0)] } ?? [])
    }

    /// The model dictation uses: the selection, or the first installed model in place of a provider's voice model
    /// that can't transcribe (OpenAI's stands while its key does).
    func dictateModel(_ local: LocalModels) -> VoiceModelReference? {
        guard case .provider? = dictateSelection.model else { return dictateSelection.model }
        if dictateSelection.model == openAIDictateReference { return dictateSelection.model }
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
        if override?.isEmpty != false, dictatesWithOpenAI(local) { return openAILanguage }
        guard override?.isEmpty != false, case .local(let id)? = dictateModel(local),
              let model = SpeechModelCatalog.model(id: id), local.isInstalled(id) else { return nil }
        return model.runtimeLanguageHint(for: dictateLanguage(for: DictateModelOption(model)))
    }

    /// The vocabulary as the model dictation uses takes it (`VocabularyRouting`); nil for an empty list. A model file
    /// from the debug override, whose kind isn't known, gets fuzzy replacement.
    func dictationVocabulary(_ local: LocalModels, override: String?, entries: [VocabularyEntry]) -> VocabularyDelivery? {
        guard !entries.isEmpty else { return nil }
        if override?.isEmpty != false, dictatesWithOpenAI(local) { return VocabularyRouting.delivery(of: entries, to: .openAI) }
        guard override?.isEmpty != false else { return .fuzzyReplacement(entries.map(\.term)) }
        guard case .local(let id)? = dictateModel(local), let model = SpeechModelCatalog.model(id: id) else { return nil }
        return VocabularyRouting.delivery(of: entries, to: .local(model.architecture))
    }

    /// The language the small cleanups take the dictation to be in: the chosen one, or what Automatic means on the model.
    /// A model file from the debug override has no selection: it gives what Automatic means on the catalog model it
    /// holds, and nil (fillers kept) for a file the catalog doesn't pin.
    func dictationCleanupLanguage(_ local: LocalModels, override: String?) -> String? {
        if let override, !override.isEmpty { return SpeechModelCatalog.model(atPath: override)?.automaticLanguage }
        if dictatesWithOpenAI(local) { return openAILanguage }
        return dictateOption(local).map(dictateLanguage(for:))
    }

    /// Deletes an installed model; Dictate forgets it when it was the one selected.
    func deleteLocalModel(_ model: SpeechModel, from local: LocalModels) async {
        guard await local.delete(model), dictateSelection.model == .local(model.id) else { return }
        selectDictate(nil, languages: nil)
        selectDictate(language: nil)
    }
}
