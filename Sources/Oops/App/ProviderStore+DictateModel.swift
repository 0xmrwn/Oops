import Foundation
import OopsCore

/// One entry of Dictate's model menu: an installed model on this Mac, or a provider's that transcribes.
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

    /// A provider's model; languages it doesn't report are taken to be any, detected.
    init(_ choice: ModelSelection.Choice, name: String, capabilities: ModelCapabilities) {
        reference = .provider(choice); self.name = name; streams = capabilities.streaming
        languages = [SpeechLanguage.auto] + (capabilities.languages ?? SpeechLanguage.listed.map(\.code).filter { $0 != SpeechLanguage.auto })
        automatic = SpeechLanguage.auto
    }
}

extension ProviderStore {
    /// Dictate's model menu: the installed models, then switched-on provider models that resolve to voice.
    func dictateOptions(_ local: LocalModels) -> [DictateModelOption] {
        let installed = local.installed.map(DictateModelOption.init)
        let voice = shownCapabilities.compactMap { choice, resolution -> DictateModelOption? in
            guard let capabilities = resolution.capabilities, capabilities.voice else { return nil }
            let name = catalogs[choice.providerID]?.first { $0.id == choice.modelID }?.name ?? choice.modelID
            return DictateModelOption(choice, name: name, capabilities: capabilities)
        }
        return installed + voice.sorted { $0.name < $1.name }
    }

    /// The selected model when it can be used now: installed, or still switched on.
    func dictateOption(_ local: LocalModels) -> DictateModelOption? {
        guard let model = dictateSelection.model else { return nil }
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
        guard case .local(let id)? = dictateSelection.model else { return nil }
        return local.fileURL(id)?.path
    }

    /// The selected language in the engine's terms; nil under Automatic, with the debug override, or for a model
    /// that takes no hint.
    func dictationLanguageHint(_ local: LocalModels, override: String?) -> String? {
        guard override?.isEmpty != false, case .local(let id)? = dictateSelection.model,
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
