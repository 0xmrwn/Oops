import OopsCore
import SwiftUI

/// Dictate's Clean up: when the model rewrites a transcript, with which model, the shortcut that cleans one
/// dictation whatever the setting, and the three small cleanups that need no model.
struct DictateCleanupCard: View {
    let store: ProviderStore
    @AppStorage(DictationCleanupMode.key) private var mode = DictationCleanupMode.off
    @AppStorage(SmallCleanups.fillersKey) private var fillers = false
    @AppStorage(SmallCleanups.formattingKey) private var formatting = false
    @AppStorage(SmallCleanups.symbolsKey) private var symbols = false
    @State private var shortcutError: String?

    /// The model matters once something can clean up: Button, Always or the shortcut.
    private var usesModel: Bool { mode != .off || ShortcutSettings.shared.custom[.dictateAndCleanUp] != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingRow(symbol: "wand.and.sparkles", title: "Clean up") {
                GlassChoice(title: "Clean up", choices: DictationCleanupMode.choices, selection: $mode)
            }
            if usesModel {
                Divider()
                SettingRow(symbol: "cpu", title: "Model") { model }
            }
            Divider()
            SettingRow(symbol: "keyboard", title: ShortcutSettings.Action.dictateAndCleanUp.title) {
                ShortcutControl(title: ShortcutSettings.Action.dictateAndCleanUp.title, action: .dictateAndCleanUp, error: $shortcutError)
            }
            if let shortcutError {
                Label(shortcutError, systemImage: "exclamationmark.triangle").font(.callout).secondaryText()
                    .fixedSize(horizontal: false, vertical: true).padding(.bottom, 10)
            }
            Divider()
            toggle("text.badge.minus", "Remove filler words", $fillers)
            Divider()
            toggle("return", "Spoken formatting", $formatting)
            Divider()
            toggle("number", "Spoken symbols", $symbols)
        }
        .padding(.vertical, -6)
        .settingsSurface()
        .animation(.easeOut(duration: 0.15), value: usesModel)
    }

    @ViewBuilder private var model: some View {
        let options = store.cleanupOptions
        if options.isEmpty {
            // Models are switched on in Providers, as Fix's are.
            Button { store.wantsProvidersPage = true } label: { Label("Switch on a model", systemImage: "switch.2") }
                .buttonStyle(.settingsGlass).controlSize(.large)
        } else {
            // Under their providers' names, as Fix's picker lists them: two providers can serve the same model.
            GlassMenu(title: "Clean up model", choices: options.map { (Optional($0), store.modelName($0)) },
                      selection: Binding(get: { store.cleanupChoice }, set: { if let choice = $0 { store.selectCleanup(choice) } }),
                      section: { $0.flatMap { store.provider($0.providerID)?.name } })
        }
    }

    private func toggle(_ symbol: String, _ title: String, _ isOn: Binding<Bool>) -> some View {
        SettingRow(symbol: symbol, title: title) { Toggle(title, isOn: isOn).settingsSwitch().labelsHidden() }
    }
}
