import OopsCore
import SwiftUI

/// Dictate's microphone and what the Mac's sound does while a dictation records. Each applies to the next dictation.
struct DictateAudioCard: View {
    @AppStorage(DictationAudioSettings.microphoneKey) private var microphone = ""
    @State private var microphones = SettingsMicrophones()
    @AppStorage(DictationAudioSettings.keepReadyKey) private var keepReady = false
    @AppStorage(DictationAudioSettings.avoidBluetoothKey) private var avoidBluetooth = true
    @AppStorage(DictationAudioSettings.whileDictatingKey) private var whileDictating = DictationWhileDictating.nothing
    @AppStorage(DictationAudioSettings.lowerLevelKey) private var lowerLevel = DictationAudioSettings.defaultLowerLevel

    private static let whileChoices: [(value: DictationWhileDictating, label: String)] = [
        (.nothing, "Do nothing"), (.mute, "Mute"), (.pauseMedia, "Pause media"), (.lowerAudio, "Lower audio"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingRow(symbol: "mic.and.signal.meter", title: "Microphone") {
                // The system default, then every microphone by name: the empty value is the default.
                let menu = SettingsMicrophones.menu(microphones.snapshot, avoidBluetooth: avoidBluetooth)
                GlassMenu(title: "Microphone", choices: menu.choices, selection: $microphone, placeholder: menu.placeholder)
            }
            Divider()
            SettingRow(symbol: "bolt", title: "Keep the microphone ready") {
                HStack(spacing: 10) {
                    InfoTip("Ready, a dictation starts at once and macOS shows the microphone in use all the time. Off, the first moment of a dictation can be clipped.")
                    Toggle("Keep the microphone ready", isOn: $keepReady).settingsSwitch().labelsHidden()
                }
            }
            Divider()
            SettingRow(symbol: "airpods", title: "Avoid Bluetooth microphones") {
                Toggle("Avoid Bluetooth microphones", isOn: $avoidBluetooth).settingsSwitch().labelsHidden()
            }
            Divider()
            SettingRow(symbol: "speaker.wave.2", title: "While dictating") {
                GlassMenu(title: "While dictating", choices: Self.whileChoices, selection: $whileDictating)
            }
            if whileDictating == .lowerAudio {
                Divider()
                SettingRow(symbol: "speaker.wave.1", title: "Level") {
                    HStack(spacing: 10) {
                        Slider(value: $lowerLevel, in: 0 ... 1).frame(width: 160).accessibilityLabel("Lower audio level")
                        Text(lowerLevel, format: .percent.precision(.fractionLength(0))).monospacedDigit().secondaryText()
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            }
        }
        .padding(.vertical, -6)
        .settingsSurface()
        .animation(.easeOut(duration: 0.15), value: whileDictating)
    }
}
