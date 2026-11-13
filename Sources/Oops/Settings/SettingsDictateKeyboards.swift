import OopsCore
import SwiftUI

/// Dictate → Keyboards: selecting a keyboard can switch Dictate to a model and language. Shown once a model is
/// installed, or while a mapping remains to be cleared.
struct DictateKeyboardsCard: View {
    let local: LocalModels
    let keyboards: KeyboardModelDriver
    let sources: [KeyboardInputSource]?
    @State private var system: [KeyboardInputSource] = []

    private var listed: [KeyboardInputSource] { sources ?? system }

    var body: some View {
        Group {
            if !listed.isEmpty, !local.installed.isEmpty || !keyboards.settings.mappings.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Label { Text("Keyboards").font(.headline) } icon: {
                        Image(systemName: "keyboard").font(.system(size: 15, weight: .medium)).secondaryText()
                    }
                    .padding(.bottom, 6)
                    ForEach(Array(listed.enumerated()), id: \.element.id) { index, source in
                        if index > 0 { Divider() }
                        KeyboardMappingRow(source: source, local: local, keyboards: keyboards)
                    }
                }
                .settingsSurface()
            }
        }
        .task { if sources == nil { system = KeyboardInputSources.shared.enabled() } }
    }
}

/// One keyboard: Don't switch, or an installed model and, when it has a choice, the language.
private struct KeyboardMappingRow: View {
    let source: KeyboardInputSource
    let local: LocalModels
    let keyboards: KeyboardModelDriver

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
            GlassMenu(title: "\(source.name) model", choices: [("", "Don’t switch")] + local.installed.map { ($0.id, $0.name) },
                      selection: Binding(get: { choice?.modelID ?? "" }, set: map), placeholder: "Not installed")
        }
        .padding(.vertical, 6)
    }

    private func map(_ id: String) {
        guard let model = SpeechModelCatalog.model(id: id) else { return keyboards.setMapping(nil, for: source.id) }
        guard keyboards.mapping(source.id)?.modelID != id else { return }
        keyboards.setMapping(KeyboardModelChoice(modelID: id, language: source.language(for: model, fallback: model.automaticLanguage)),
                             for: source.id)
    }
}
