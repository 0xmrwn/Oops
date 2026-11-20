import OopsCore
import SwiftUI

/// Dictate's Clean up: how far a transcript is cleaned (Off, Basic's small cleanups on the Mac, or AI's model on top),
/// the small cleanups themselves, the model, and the shortcut that has the model clean one dictation whatever the level.
struct DictateCleanupCard: View {
    let store: ProviderStore
    @AppStorage(DictationCleanupMode.key) private var mode = DictationCleanupMode.off
    @AppStorage(SmallCleanups.fillersKey) private var fillers = false
    @AppStorage(SmallCleanups.formattingKey) private var formatting = false
    @AppStorage(SmallCleanups.symbolsKey) private var symbols = false
    @State private var shortcutError: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingRow(symbol: "wand.and.sparkles", title: "Clean up") {
                HStack(spacing: 10) {
                    InfoTip("Clean up", "Basic tidies what you said on your Mac, instantly. AI also has a model rewrite it, which takes a few seconds.") {
                        CleanupExamples()
                    }
                    GlassChoice(title: "Clean up", choices: DictationCleanupMode.choices, selection: Binding(get: { mode }, set: choose))
                }
            }
            if mode != .off {
                VStack(spacing: 0) {
                    toggle("text.badge.minus", "Remove filler words", $fillers)
                    toggle("return", "Spoken formatting", $formatting)
                    toggle("number", "Spoken symbols", $symbols)
                }
                .padding(.bottom, 6)
                // As the keyboard rows open under their switch: the card makes room and the rows settle in from just
                // above; closing, they fade first, so none shows past the card's shrinking edge.
                .transition(.asymmetric(
                    insertion: reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.975, anchor: .top))
                        .combined(with: .offset(y: -6)),
                    removal: .opacity.animation(.easeOut(duration: 0.12))))
            }
            SettingRow(symbol: "cpu", title: "Model") { model }
            SettingRow(symbol: "keyboard", title: ShortcutSettings.Action.dictateAndCleanUp.title) {
                HStack(spacing: 10) {
                    InfoTip("Cleans your last dictation while it’s still where Oops wrote it. Otherwise, dictates and cleans.")
                    ShortcutControl(title: ShortcutSettings.Action.dictateAndCleanUp.title, action: .dictateAndCleanUp, error: $shortcutError)
                }
            }
            if let shortcutError {
                Label(shortcutError, systemImage: "exclamationmark.triangle").font(.callout).secondaryText()
                    .fixedSize(horizontal: false, vertical: true).padding(.bottom, 10)
            }
        }
        .padding(.vertical, -6)
        .settingsSurface()
    }

    /// A level that cleans with every small cleanup off would do nothing on the Mac: choosing it switches them all on.
    private func choose(_ level: DictationCleanupMode) {
        withAnimation(SettingsMotion.swap(reduceMotion)) {
            if level != .off, !fillers, !formatting, !symbols { fillers = true; formatting = true; symbols = true }
            mode = level
        }
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

    /// A small cleanup, under the level it belongs to: indented, with a lighter icon and title than the card's rows.
    private func toggle(_ symbol: String, _ title: String, _ isOn: Binding<Bool>) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 14, weight: .medium)).frame(width: 20).secondaryText().accessibilityHidden(true)
            Text(title).fontWeight(.medium)
            Spacer(minLength: 8)
            Toggle(title, isOn: isOn).settingsSwitch().labelsHidden()
        }
        .padding(.vertical, 6).frame(minHeight: 40)
        .padding(.leading, 38)
    }
}
