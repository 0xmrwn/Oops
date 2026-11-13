import OopsCore
import SwiftUI

extension DictationMode {
    /// Where Settings keeps the mode, by raw value.
    static let key = "DictationMode"
    /// The mode as saved, hold or tap until one is chosen.
    static var saved: DictationMode { UserDefaults.standard.string(forKey: key).flatMap(Self.init(rawValue:)) ?? .holdOrTap }
    /// The Mode menu's choices, in its order.
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
                Label(shortcutError, systemImage: "exclamationmark.triangle").font(.callout).secondaryText()
                    .fixedSize(horizontal: false, vertical: true).padding(.bottom, 10)
            }
            Divider()
            SettingRow(symbol: "hand.tap", title: "Mode") { GlassMenu(title: "Mode", choices: DictationMode.choices, selection: $mode) }
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

    /// The one place Oops asks for the microphone: as Dictate first gets a shortcut, when this build can
    /// dictate and the question was never asked. A build without the engine may not touch the microphone.
    private static func askForMicrophone() {
        guard DictationEngineProvider.engine() != nil, DictationMicrophoneAccess.current == .undetermined else { return }
        Task { _ = await DictationMicrophoneAccess.requestAccess() }
    }
}

/// How the dictation drop looks and where it sits; both apply to the next dictation.
struct DictateDropCard: View {
    @AppStorage(DictationVisualizer.defaultsKey) private var visualizer = DictationVisualizer.standard
    @AppStorage(DictationDropPosition.key) private var position = DictationDropPosition.anchored

    private static let visualizers: [(value: DictationVisualizer, label: String)] = [(.hex, "Hex"), (.wave, "Wave"), (.ripple, "Ripple")]
    private static let positions: [(value: DictationDropPosition, label: String)] = [(.anchored, "By the text"), (.top, "Top"), (.bottom, "Bottom")]

    var body: some View {
        VStack(spacing: 0) {
            SettingRow(symbol: "circle.grid.3x3", title: "Visualizer") {
                GlassChoice(title: "Visualizer", choices: Self.visualizers, selection: $visualizer)
            }
            Divider()
            SettingRow(symbol: "rectangle.bottomhalf.inset.filled", title: "Position") {
                GlassChoice(title: "Position", choices: Self.positions, selection: $position)
            }
        }
        .padding(.vertical, -6)
        .settingsSurface()
    }
}
