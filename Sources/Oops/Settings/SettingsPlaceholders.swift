import OopsCore
import SwiftUI

// Dictate and Actions as they are planned, drawn with the controls they will use and every one not yet
// wired disabled. The dictation work replaces each control's constant with its setting: the shortcut and
// the mode are live, as are the drop's visualizer and position; Actions comes with the action library.

/// Dictate's settings: the shortcut and the mode, then the planned speech model, cleanup, drop and vocabulary.
struct DictatePage: View {
    let store: ProviderStore
    var local = LocalModels.shared
    var keyboards = KeyboardModelDriver.shared
    /// The keyboards to map; this Mac's enabled ones unless a snapshot passes others.
    var sources: [KeyboardInputSource]?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            DictateShortcutCard()
            DictateModelCard(store: store, local: local, keyboards: keyboards)
            DictateKeyboardsCard(local: local, keyboards: keyboards, sources: sources)
            DictateDropCard()
            planned.disabled(true)
        }
    }

    private var planned: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingRow(symbol: "mic.and.signal.meter", title: "Microphone") { menu("Microphone", ["System default"]) }
                .settingsSurface()
            SettingRow(symbol: "wand.and.sparkles", title: "Clean up") { choice("Clean up", ["Off", "Button", "Always"]) }
                .settingsSurface()
            SettingRow(symbol: "text.bubble", title: "Live words") { choice("Live words", ["In the drop", "Over the text"]) }
                .settingsSurface()
            SettingRow(symbol: "character.book.closed", title: "Vocabulary") { Chevron() }
                .settingsSurface()
        }
    }

    /// The first value is the one the setting will start with.
    private func menu(_ title: String, _ values: [String]) -> some View {
        GlassMenu(title: title, choices: values.map { ($0, $0) }, selection: .constant(values[0]))
    }

    private func choice(_ title: String, _ values: [String]) -> some View {
        GlassChoice(title: title, choices: values.map { ($0, $0) }, selection: .constant(values[0]))
    }
}

/// Actions' planned settings: its shortcut (none, so off) and the action library.
struct ActionsPage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingRow(symbol: SettingsTab.actions.symbol, title: "Run an action") {
                ShortcutField { ShortcutPrompt("Record shortcut") }
            }
            .settingsSurface()
            SettingRow(symbol: "square.stack", title: "Library") { Chevron() }
                .settingsSurface()
        }
        .disabled(true)
    }
}

/// A page row in Fix's style: icon, name, and the control on the trailing edge.
struct SettingRow<Control: View>: View {
    let symbol: String
    let title: String
    @ViewBuilder var control: Control

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 18, weight: .medium)).frame(width: 24)
                .secondaryText().accessibilityHidden(true)
            Text(title).fontWeight(.semibold)
            Spacer(minLength: 8)
            control
        }
        .padding(.vertical, 6)
        .frame(minHeight: 44)
    }
}

/// A row that opens a page of its own.
private struct Chevron: View {
    var body: some View { Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).secondaryText() }
}
