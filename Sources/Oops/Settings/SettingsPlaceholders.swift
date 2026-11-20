import OopsCore
import SwiftUI

// Actions as it is planned, drawn with the controls it will use and every one not yet wired disabled; it comes
// with the action library. Dictate's settings are all live.

/// Dictate's settings: the shortcut and the mode, the speech model and its vocabulary, the microphone and audio,
/// cleanup, the drop, and the history.
struct DictatePage: View {
    let store: ProviderStore
    var local = LocalModels.shared
    var keyboards = KeyboardModelDriver.shared
    /// The keyboards to map; this Mac's enabled ones unless a snapshot passes others.
    var sources: [KeyboardInputSource]?
    var picker = SpeechModelPicker.shared
    @Binding var detail: DictateDetail?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .top) {
            if let target = picker.target {
                SpeechModelPage(target: target, store: store, local: local) { picker.target = nil }
                    .drillPane(edge: 1, reduceMotion: reduceMotion)
            } else if detail == .history {
                VStack(alignment: .leading, spacing: 20) {
                    DrillHeader(title: "History", parent: "Dictate", back: { detail = nil }) {
                        Image(systemName: DictationHistoryPage.symbol).font(.system(size: 18, weight: .medium))
                    }
                    DictationHistoryPage()
                }
                .drillPane(edge: 1, reduceMotion: reduceMotion)
            } else if detail == .vocabulary {
                VStack(alignment: .leading, spacing: 20) {
                    DrillHeader(title: "Vocabulary", parent: "Dictate", back: { detail = nil }) {
                        Image(systemName: "character.book.closed").font(.system(size: 18, weight: .medium))
                    }
                    VocabularyPage()
                }
                .drillPane(edge: 1, reduceMotion: reduceMotion)
            } else {
                dictate.drillPane(edge: -1, reduceMotion: reduceMotion)
            }
        }
        .animation(SettingsMotion.drill(reduceMotion), value: detail)
        .animation(SettingsMotion.drill(reduceMotion), value: picker.target != nil)
    }

    private var dictate: some View {
        VStack(alignment: .leading, spacing: 20) {
            // What starting needs, then what decides the words, then how the drop looks.
            DictateShortcutCard()
            DictateModelCard(store: store, local: local, keyboards: keyboards, sources: sources) { detail = .vocabulary }
            DictateAudioCard()
            DictateCleanupCard(store: store)
            DictateDropCard(store: store, local: local)
            DictateHistoryCard { detail = .history }
        }
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
struct Chevron: View {
    var body: some View { Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).secondaryText() }
}
