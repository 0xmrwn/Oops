import OopsCore
import SwiftUI

// Dictate and Actions as they are planned, drawn with the controls they will use and every one disabled:
// nothing here is wired yet. The dictation work replaces each control's constant with its setting,
// starting with the shortcut; Actions comes with the action library.

/// Dictate's planned settings: the shortcut, the speech model, cleanup, the drop and vocabulary.
struct DictatePage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(spacing: 0) {
                SettingRow(symbol: SettingsTab.dictate.symbol, title: "Dictate") {
                    ShortcutField { ShortcutPrompt("Record shortcut") }
                }
                Divider()
                SettingRow(symbol: "hand.tap", title: "Mode") {
                    Picker("Mode", selection: .constant("Hold or tap")) {
                        ForEach(["Hold or tap", "Hold to talk", "Tap to start and stop"], id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.menu).fixedSize()
                }
            }
            .padding(.vertical, -6)
            .settingsSurface()
            VStack(spacing: 0) {
                SettingRow(symbol: "waveform", title: "Speech model") {
                    Button {} label: {
                        HStack(spacing: 6) {
                            Text("Choose a model").fontWeight(.medium)
                            Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).secondaryText()
                        }
                    }
                    .buttonStyle(.settingsGlass).controlSize(.large)
                }
                Divider()
                SettingRow(symbol: "globe", title: "Language") { menu("Automatic") }
                Divider()
                SettingRow(symbol: "mic.and.signal.meter", title: "Microphone") { menu("System default") }
            }
            .padding(.vertical, -6)
            .settingsSurface()
            SettingRow(symbol: "wand.and.sparkles", title: "Clean up") { segments(["Off", "Button", "Always"]) }
                .settingsSurface()
            VStack(spacing: 0) {
                SettingRow(symbol: "circle.grid.3x3", title: "Visualizer") { segments(["Hex", "Wave", "Ripple"]) }
                Divider()
                SettingRow(symbol: "rectangle.bottomhalf.inset.filled", title: "Position") { segments(["By the text", "Top", "Bottom"]) }
                Divider()
                SettingRow(symbol: "text.bubble", title: "Live words") { segments(["In the drop", "Over the text"]) }
            }
            .padding(.vertical, -6)
            .settingsSurface()
            SettingRow(symbol: "character.book.closed", title: "Vocabulary") { Chevron() }
                .settingsSurface()
        }
        .disabled(true)
    }

    private func menu(_ value: String) -> some View {
        Picker(value, selection: .constant(value)) { Text(value).tag(value) }.labelsHidden().pickerStyle(.menu).fixedSize()
    }

    private func segments(_ values: [String]) -> some View {
        Picker(values[0], selection: .constant(values[0])) { ForEach(values, id: \.self) { Text($0).tag($0) } }
            .labelsHidden().pickerStyle(.segmented).fixedSize()
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
private struct SettingRow<Control: View>: View {
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
