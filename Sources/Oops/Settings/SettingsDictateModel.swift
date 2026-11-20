import AppKit
import OopsCore
import SwiftUI

/// Dictate's speech model, chosen in the picker, the language it hears and whether it follows the keyboard.
struct DictateModelCard: View {
    let store: ProviderStore
    let local: LocalModels
    let keyboards: KeyboardModelDriver
    let sources: [KeyboardInputSource]?
    /// Opens Vocabulary, which the speech model takes or which corrects what it heard.
    let vocabulary: () -> Void

    var body: some View {
        let current = store.dictateOption(local)
        VStack(spacing: 0) {
            SettingRow(symbol: "waveform", title: "Speech model") {
                Button { pick(current) } label: {
                    HStack(spacing: 7) {
                        if let current { SpeechModelMark(maker: Self.maker(current.reference), size: 15) }
                        Text(current?.name ?? "Choose a model").fontWeight(.medium)
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                }
                .buttonStyle(.settingsGlass).controlSize(.large)
                .accessibilityLabel("Speech model").accessibilityValue(current?.name ?? "None")
            }
            if let current {
                SettingRow(symbol: "globe", title: "Language") {
                    if current.isSingleLanguage {
                        Text(Self.name(current.languages[0])).fontWeight(.medium).secondaryText()
                    } else {
                        GlassMenu(title: "Language", choices: current.languages.map { ($0, Self.name($0)) },
                                  selection: Binding(get: { store.dictateLanguage(for: current) }, set: { store.chooseDictateLanguage($0) }))
                    }
                }
            }
            Button(action: vocabulary) {
                SettingRow(symbol: "character.book.closed", title: "Vocabulary") { Chevron() }.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            DictateKeyboardSwitch(local: local, keyboards: keyboards, sources: sources)
        }
        .padding(.vertical, -6)
        .settingsSurface()
        .task { await local.refresh() }
    }

    /// The picks are for the language Dictate hears; with no model yet, the one first run would infer.
    private func pick(_ current: DictateModelOption?) {
        let language = current.map(store.dictateLanguage(for:))
            ?? SpeechLanguage.firstRun(preferred: Locale.preferredLanguages, keyboards: KeyboardInputSources.shared.enabled().map(\.languages))
        SpeechModelPicker.shared.target = SpeechModelPickerTarget(id: "dictate", language: language, current: { store.dictateModel(local) }, choose: choose)
    }

    static func maker(_ reference: VoiceModelReference) -> SpeechModelMaker? {
        if case .local(let id) = reference { return SpeechModelCatalog.model(id: id)?.maker }
        return .openAI
    }

    private func choose(_ reference: VoiceModelReference) {
        guard reference != store.dictateSelection.model else { return }
        // Picked by hand: it stands until the keyboard changes again.
        keyboards.manualChoice()
        store.chooseDictateModel(reference)
        (NSApp.delegate as? AppDelegate)?.warmUpDictation()
    }

    static func name(_ code: String) -> String {
        code == SpeechLanguage.auto ? "Automatic" : SpeechLanguage.name(of: code)
    }
}
