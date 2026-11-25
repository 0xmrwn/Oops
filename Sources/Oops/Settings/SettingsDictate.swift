import OopsCore
import SwiftUI

extension DictationMode {
    /// Where Settings keeps the mode, by raw value.
    static let key = "DictationMode"
    /// The mode as saved, hold or tap until one is chosen.
    static var saved: DictationMode { UserDefaults.standard.string(forKey: key).flatMap(Self.init(rawValue:)) ?? .holdOrTap }
    /// The Shortcut mode menu's choices, in its order.
    static let choices: [(value: DictationMode, label: String)] = [
        (.holdOrTap, "Hold or tap"), (.holdOrDoubleTap, "Hold or double-tap"), (.holdOnly, "Hold only"), (.tapOnly, "Tap only"),
    ]
}

/// Dictate's shortcut, which is its switch (none, off), and how its presses start and end a recording.
struct DictateShortcutCard: View {
    @AppStorage(DictationMode.key) private var mode = DictationMode.holdOrTap
    @State private var shortcutError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingRow(symbol: SettingsTab.dictate.symbol, title: "Dictate") {
                ShortcutControl(title: "Dictate", action: .dictate, error: $shortcutError)
            }
            if let shortcutError {
                ShortcutErrorLine(error: shortcutError, action: .dictate).padding(.bottom, 10)
            }
            // Once refused, the system never asks again: this is the way back.
            if ShortcutSettings.shared.shortcut(.dictate) != nil, DictationMicrophoneAccess.current == .denied {
                HStack {
                    Label("Microphone access is off", systemImage: "mic.slash").font(.callout).secondaryText()
                    Spacer(minLength: 12)
                    Button("Open System Settings", action: MicrophoneStep.openSettings).buttonStyle(.settingsGlass)
                }
                .padding(.bottom, 10)
            }
            SettingRow(symbol: "hand.tap", title: "Shortcut mode") {
                HStack(spacing: 10) {
                    InfoTip("Shortcut mode", "How pressing your Dictate shortcut starts and stops listening. Clean up with AI works the same way.") {
                        ShortcutModeGuide(selected: mode)
                    }
                    GlassMenu(title: "Shortcut mode", choices: DictationMode.choices, selection: $mode)
                }
            }
        }
        .padding(.vertical, -6)
        .settingsSurface()
        .animation(.easeOut(duration: 0.15), value: ShortcutSettings.shared.custom)
        .onChange(of: ShortcutSettings.shared.custom[.dictate]) { old, new in
            // Dictate just went off: nothing is left to end a recording under way.
            if new == nil { (NSApp.delegate as? AppDelegate)?.dictation?.turnedOff() }
            guard old == nil, new != nil else { return }
            Self.askForMicrophone()
            // Dictate just came on: the model warms now, as it would have at launch.
            (NSApp.delegate as? AppDelegate)?.warmUpDictation()
        }
    }

    /// The one place Oops asks for the microphone: as Dictate first gets a shortcut, when the question was never asked.
    private static func askForMicrophone() {
        guard DictationMicrophoneAccess.current == .undetermined else { return }
        Task { _ = await DictationMicrophoneAccess.requestAccess() }
    }
}

/// How the dictation drop looks, where it sits and where the words show while speaking; each applies to the next
/// dictation.
struct DictateDropCard: View {
    let store: ProviderStore
    let local: LocalModels
    @AppStorage(DictationVisualizer.defaultsKey) private var visualizer = DictationVisualizer.standard
    @AppStorage(DictationDropPosition.key) private var position = DictationDropPosition.anchored
    @AppStorage(DictationLiveWordsPlace.key) private var place = DictationLiveWordsPlace.drop

    private static let visualizers: [(value: DictationVisualizer, label: String)] = [(.hex, "Hex"), (.string, "String"), (.wave, "Wave")]
    private static let positions: [(value: DictationDropPosition, label: String)] = [(.anchored, "By the text"), (.top, "Top"), (.bottom, "Bottom")]
    private static let places: [(value: DictationLiveWordsPlace, label: String)] = [(.drop, "In the drop"), (.text, "At the caret")]

    var body: some View {
        VStack(spacing: 0) {
            SettingRow(symbol: "alternatingcurrent", title: "Animation") {
                HStack(spacing: 10) {
                    InfoTip("Animation", "How the drop shows your voice while you dictate.") {
                        AnimationPreview(kind: visualizer, label: Self.visualizers.first { $0.value == visualizer }?.label ?? "")
                    }
                    GlassChoice(title: "Animation", choices: Self.visualizers, selection: $visualizer)
                }
            }
            SettingRow(symbol: "rectangle.bottomhalf.inset.filled", title: "Position") {
                HStack(spacing: 10) {
                    InfoTip("Position", "Where the drop shows while you dictate. By the text, it sits beside the field you’re writing in, or at the bottom when an app doesn’t say where that is.") {
                        DropPositionPreview(selected: position)
                    }
                    GlassChoice(title: "Position", choices: Self.positions, selection: $position)
                }
            }
            SettingRow(symbol: "text.bubble", title: "Live words") {
                HStack(spacing: 10) {
                    // A model that only transcribes once the recording ends has no words to show while speaking.
                    let streams = store.dictateOption(local)?.streams != false
                    InfoTip("Live words", streams ? "Your words show as you speak, in the drop or greyed out where they’ll be written."
                        : "This speech model writes your words once you stop speaking. With a model that streams, they show as you speak, like this.") {
                        LiveWordsPreview()
                    }
                    if streams {
                        GlassChoice(title: "Live words", choices: Self.places, selection: $place)
                    } else {
                        Text("Not with this model").fontWeight(.medium).secondaryText()
                    }
                }
            }
        }
        .padding(.vertical, -6)
        .settingsSurface()
    }
}
