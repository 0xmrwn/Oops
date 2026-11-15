import Foundation
import Observation
import OopsCore

/// The microphones Dictate's Microphone row offers, kept current as inputs come and go, the default changes or
/// the lid opens or closes.
@MainActor @Observable final class SettingsMicrophones {
    private(set) var snapshot: MicrophoneDevices.Snapshot
    @ObservationIgnored private var token: UUID?

    init() {
        snapshot = MicrophoneDevices.snapshot()
        token = MicrophoneWatch.shared.observe { [weak self] in
            Task { @MainActor in self?.snapshot = MicrophoneDevices.snapshot() }
        }
    }

    isolated deinit { if let token { MicrophoneWatch.shared.stop(token) } }

    /// The row's choices, "System default" (the empty value) naming the input it records from now, then every input
    /// by name; and what the row shows while the picked microphone is not connected.
    nonisolated static func menu(_ snapshot: MicrophoneDevices.Snapshot,
                                 avoidBluetooth: Bool) -> (choices: [(value: String, label: String)], placeholder: String) {
        let inUse = MicrophoneChoice.systemDefault(inputs: snapshot.inputs, defaultUID: snapshot.defaultUID,
                                                   route: snapshot.route(avoidBluetooth: avoidBluetooth))
        let named = { (label: String) in inUse.map { "\(label) · \($0.name)" } ?? label }
        let inputs = snapshot.inputs.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return ([("", named("System default"))] + inputs.map { ($0.uid, $0.name) }, named("Not connected"))
    }
}
