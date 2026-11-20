import OopsCore
import SwiftUI

/// The Speech model card's keyboard switching: a switch, then, while it is on, a model and language for each
/// keyboard. Shown only on a Mac with more than one keyboard, once a model is installed or while switching is on.
struct DictateKeyboardSwitch: View {
    let local: LocalModels
    let keyboards: KeyboardModelDriver
    let sources: [KeyboardInputSource]?
    /// Read as the view is made: a task on a view that shows nothing yet would never run.
    @State private var system = KeyboardInputSources.shared.enabled()

    private var listed: [KeyboardInputSource] { sources ?? system }

    var body: some View {
        if listed.count > 1, !local.installed.isEmpty || keyboards.settings.enabled {
            SettingsDivider()
            SettingRow(symbol: "keyboard", title: "Switch with keyboard") {
                HStack(spacing: 10) {
                    InfoTip("Pick a speech model and language for each keyboard. Dictate switches to them when you change keyboards.")
                    Toggle("Switch with keyboard", isOn: Binding(get: { keyboards.settings.enabled }, set: keyboards.setEnabled))
                        .settingsSwitch().labelsHidden()
                }
            }
            if keyboards.settings.enabled {
                ForEach(listed) { source in
                    SettingsDivider().padding(.leading, 38)
                    KeyboardMappingRow(source: source, local: local, keyboards: keyboards).padding(.leading, 38)
                }
            }
        }
    }
}

/// One keyboard: Don't switch, or an installed model and, when it has a choice, the language. More models opens
/// the picker for the keyboard's language.
private struct KeyboardMappingRow: View {
    let source: KeyboardInputSource
    let local: LocalModels
    let keyboards: KeyboardModelDriver
    private static let more = "more"

    var body: some View {
        let choice = keyboards.mapping(source.id)
        let model = choice.flatMap { local.isInstalled($0.modelID) ? SpeechModelCatalog.model(id: $0.modelID) : nil }
        HStack(spacing: 10) {
            Text(source.name).fontWeight(.medium).lineLimit(1)
            Spacer(minLength: 8)
            if let choice, let model, !model.isSingleLanguage {
                GlassMenu(title: "\(source.name) language", choices: model.languageChoices.map { ($0, DictateModelCard.name($0)) },
                          selection: Binding(get: { choice.language }, set: {
                              keyboards.setMapping(KeyboardModelChoice(modelID: model.id, language: $0), for: source.id)
                          }), placeholder: DictateModelCard.name(choice.language))
            }
            // A mapped model deleted since shows as Not installed until it is cleared or replaced.
            GlassMenu(title: "\(source.name) model", choices: [("", "Don’t switch")] + local.installed.map { ($0.id, $0.name) } + [(Self.more, "More models…")],
                      selection: Binding(get: { choice?.modelID ?? "" }, set: map), placeholder: "Not installed")
        }
        .padding(.vertical, 6)
    }

    private func map(_ id: String) {
        guard id != Self.more else { return pick() }
        // Picked from the menu: it stands over a download still coming in for this keyboard.
        SpeechModelPicker.shared.chose(for: source.id)
        guard let model = SpeechModelCatalog.model(id: id) else { return keyboards.setMapping(nil, for: source.id) }
        guard keyboards.mapping(source.id)?.modelID != id else { return }
        keyboards.setMapping(KeyboardModelChoice(modelID: id, language: source.language(for: model, fallback: model.automaticLanguage)),
                             for: source.id)
    }

    private func pick() {
        let language = source.languages.lazy
            .map { $0.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? $0 }
            .first(where: SpeechLanguage.isKnown) ?? "en"
        SpeechModelPicker.shared.target = SpeechModelPickerTarget(
            id: source.id, language: language, offersOpenAI: false,
            current: { keyboards.mapping(source.id).map { .local($0.modelID) } },
            choose: { if case .local(let id) = $0 { map(id) } })
    }
}
