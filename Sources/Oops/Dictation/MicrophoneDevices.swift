import CoreAudio
import Foundation
import IOKit
import OopsCore

/// The Mac's input devices as `MicrophoneChoice` sees them, read from CoreAudio, and whether the lid is closed.
/// Reading them opens no microphone.
enum MicrophoneDevices {
    /// What a microphone is chosen from, at one moment.
    struct Snapshot: Sendable {
        var inputs: [MicrophoneInput] = []
        /// Each listed input's device, by UID.
        var devices: [String: AudioDeviceID] = [:]
        var defaultUID: String?
        var defaultDevice: AudioDeviceID?
        var lidClosed = false

        func route(avoidBluetooth: Bool) -> MicrophoneRoute { MicrophoneRoute(lidClosed: lidClosed, avoidBluetooth: avoidBluetooth) }

        /// The device and input a plan records from. A default that is not listed has a device but no input.
        func resolve(_ plan: MicrophonePlan) -> (device: AudioDeviceID, uid: String, name: String)? {
            if let input = MicrophoneChoice.input(of: plan, in: inputs, defaultUID: defaultUID), let device = devices[input.uid] {
                return (device, input.uid, input.name)
            }
            guard plan.target == .systemDefault, let defaultDevice else { return nil }
            return (defaultDevice, defaultUID ?? "", defaultUID ?? "")
        }
    }

    static func snapshot() -> Snapshot {
        var snapshot = Snapshot(lidClosed: lidClosed())
        for device in inputDevices() {
            // A device whose UID or name cannot be read cannot be picked or named, so it is left out.
            guard let uid = string(device, kAudioDevicePropertyDeviceUID), let name = string(device, kAudioObjectPropertyName) else { continue }
            let dataSource = uint32(device, kAudioDevicePropertyDataSource, scope: kAudioObjectPropertyScopeInput)
            let kind = uint32(device, kAudioDevicePropertyTransportType) ?? 0
            snapshot.inputs.append(MicrophoneInput(uid: uid, name: name, transport: transport(kind: kind, uid: uid, dataSource: dataSource)))
            snapshot.devices[uid] = device
        }
        snapshot.defaultDevice = uint32(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice)
            .flatMap { $0 == kAudioObjectUnknown ? nil : $0 }
        snapshot.defaultUID = snapshot.defaultDevice.flatMap { string($0, kAudioDevicePropertyDeviceUID) }
        return snapshot
    }

    /// How CoreAudio reports a device connects. A headphone-jack microphone counts as other, since closing the lid
    /// leaves it on. Ported from Hex's `src/audio/transport.rs` (v3.4.0).
    static func transport(kind: UInt32, uid: String, dataSource: UInt32?) -> MicrophoneTransport {
        switch kind {
        case kAudioDeviceTransportTypeBuiltIn: isLidSwitchedMicrophone(uid: uid, dataSource: dataSource) ? .builtIn : .other
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: .bluetooth
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate: .virtual
        case kAudioDeviceTransportTypeContinuityCaptureWired, kAudioDeviceTransportTypeContinuityCaptureWireless: .continuity
        default: .other
        }
    }

    /// Whether a built-in input is the internal microphone the lid switches off. A microphone in the headphone jack
    /// is built in too, but stays on with the lid closed: Apple silicon lists it as its own device
    /// (`BuiltInHeadphoneInputDevice`), older Macs as the built-in input's external-microphone or line-in source.
    static func isLidSwitchedMicrophone(uid: String, dataSource: UInt32?) -> Bool {
        if uid.contains("HeadphoneInput") { return false }
        return dataSource != fourCC("emic") && dataSource != fourCC("line")
    }

    /// Whether a MacBook's lid is closed, which switches its built-in microphone off in hardware while CoreAudio
    /// still lists it, often as the default input. Read from `AppleClamshellState` on the power root domain; Macs
    /// without a lid read open.
    static func lidClosed() -> Bool {
        let root = rootDomain
        guard root != 0,
              let value = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
        else { return false }
        return value.takeRetainedValue() as? Bool ?? false
    }

    /// The power root domain, kept for the life of the process; 0 when there is none.
    static let rootDomain: io_service_t = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))

    static func fourCC(_ code: String) -> UInt32 { code.utf8.reduce(0) { $0 << 8 | UInt32($1) } }

    /// Every device with at least one input stream.
    private static func inputDevices() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &devices) == noErr else { return [] }
        return devices.filter { device in
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput,
                                                     mElement: kAudioObjectPropertyElementMain)
            var streamsSize: UInt32 = 0
            return AudioObjectGetPropertyDataSize(device, &streams, 0, nil, &streamsSize) == noErr && streamsSize > 0
        }
    }

    private static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                               scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        return status == noErr && size == UInt32(MemoryLayout<UInt32>.size) ? value : nil
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        let string = value.takeRetainedValue() as String
        return string.isEmpty ? nil : string
    }
}
