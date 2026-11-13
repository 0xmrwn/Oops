import AppKit
import OopsCore
import SwiftUI

/// Dictate's speech model, from the installed ones and providers' that transcribe, and the language it hears.
struct DictateModelCard: View {
    let store: ProviderStore
    let local: LocalModels
    let keyboards: KeyboardModelDriver

    var body: some View {
        let options = store.dictateOptions(local), current = store.dictateOption(local)
        VStack(spacing: 0) {
            SettingRow(symbol: "waveform", title: "Speech model") {
                if options.isEmpty {
                    // Models are downloaded on Providers, beside the rest of what Oops connects to.
                    Button { store.wantsProvidersPage = true } label: { Label("Download a model", systemImage: "arrow.down.circle") }
                        .buttonStyle(.settingsGlass).controlSize(.large)
                } else {
                    GlassMenu(title: "Speech model", choices: options.map { (Optional($0.reference), $0.name) },
                              selection: Binding(get: { current?.reference }, set: { choose($0) }), placeholder: "Choose a model")
                }
            }
            if let current {
                Divider()
                SettingRow(symbol: "globe", title: "Language") {
                    if current.isSingleLanguage {
                        Text(Self.name(current.languages[0])).fontWeight(.medium).secondaryText()
                    } else {
                        GlassMenu(title: "Language", choices: current.languages.map { ($0, Self.name($0)) },
                                  selection: Binding(get: { store.dictateLanguage(for: current) }, set: { store.chooseDictateLanguage($0) }))
                    }
                }
            }
        }
        .padding(.vertical, -6)
        .settingsSurface()
        .task { await local.refresh() }
    }

    private func choose(_ reference: VoiceModelReference?) {
        guard let reference, reference != store.dictateSelection.model else { return }
        // Picked by hand: it stands until the keyboard changes again.
        keyboards.manualChoice()
        store.chooseDictateModel(reference)
        (NSApp.delegate as? AppDelegate)?.warmUpDictation()
    }

    static func name(_ code: String) -> String {
        code == SpeechLanguage.auto ? "Automatic" : SpeechLanguage.name(of: code)
    }
}
