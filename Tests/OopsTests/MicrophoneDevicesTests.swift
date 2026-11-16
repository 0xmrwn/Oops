import CoreAudio
@testable import Oops
import OopsCore
import Testing

/// How CoreAudio's devices become `MicrophoneChoice`'s inputs, and what the Microphone row names. Nothing here
/// opens a microphone: the device list is only read.
struct MicrophoneDevicesTests {
    // From Hex's `src/audio/transport.rs` (v3.4.0).
    @Test func `only the internal microphone is switched off by the lid`() {
        let source = MicrophoneDevices.fourCC
        #expect(MicrophoneDevices.isLidSwitchedMicrophone(uid: "BuiltInMicrophoneDevice", dataSource: nil))
        #expect(MicrophoneDevices.isLidSwitchedMicrophone(uid: "AppleHDAEngineInput:1B,0,1,0:1", dataSource: source("imic")))
        #expect(!MicrophoneDevices.isLidSwitchedMicrophone(uid: "BuiltInHeadphoneInputDevice", dataSource: nil))
        #expect(!MicrophoneDevices.isLidSwitchedMicrophone(uid: "AppleHDAEngineInput:1B,0,1,0:1", dataSource: source("emic")))
        #expect(!MicrophoneDevices.isLidSwitchedMicrophone(uid: "AppleHDAEngineInput:1B,0,1,0:1", dataSource: source("line")))
    }

    // From Hex's `src/audio/transport.rs` (v3.4.0).
    @Test func `continuity capture transports are recognised`() {
        #expect(kAudioDeviceTransportTypeContinuityCaptureWired == 0x6363_7764)
        #expect(kAudioDeviceTransportTypeContinuityCaptureWireless == 0x6363_776C)
        #expect(MicrophoneDevices.transport(kind: MicrophoneDevices.fourCC("ccwd"), uid: "iPhone", dataSource: nil) == .continuity)
        #expect(MicrophoneDevices.transport(kind: MicrophoneDevices.fourCC("ccwl"), uid: "iPhone", dataSource: nil) == .continuity)
        #expect(MicrophoneDevices.transport(kind: MicrophoneDevices.fourCC("bltn"), uid: "BuiltInMicrophoneDevice", dataSource: nil) == .builtIn)
        #expect(MicrophoneDevices.transport(kind: MicrophoneDevices.fourCC("virt"), uid: "Teams", dataSource: nil) == .virtual)
    }

    @Test func `microphone transports follow how coreaudio reports each device`() {
        let transport = { (kind: UInt32) in MicrophoneDevices.transport(kind: kind, uid: "device", dataSource: nil) }
        #expect(transport(kAudioDeviceTransportTypeBluetooth) == .bluetooth)
        #expect(transport(kAudioDeviceTransportTypeBluetoothLE) == .bluetooth)
        #expect(transport(kAudioDeviceTransportTypeAggregate) == .virtual)
        #expect(transport(kAudioDeviceTransportTypeAutoAggregate) == .virtual)
        #expect(transport(kAudioDeviceTransportTypeUSB) == .other)
        #expect(MicrophoneDevices.transport(kind: kAudioDeviceTransportTypeBuiltIn, uid: "BuiltInHeadphoneInputDevice", dataSource: nil) == .other)
    }

    @Test func `the microphone list read from coreaudio names each input by its device`() {
        let snapshot = MicrophoneDevices.snapshot()
        for input in snapshot.inputs {
            #expect(!input.uid.isEmpty && !input.name.isEmpty)
            #expect(snapshot.devices[input.uid] != nil)
        }
        if let defaultUID = snapshot.defaultUID { #expect(snapshot.devices[defaultUID] == snapshot.defaultDevice) }
    }

    @Test func `the microphone row names the input system default records from`() {
        let snapshot = Self.airPodsDefault
        let avoiding = SettingsMicrophones.menu(snapshot, avoidBluetooth: true)
        #expect(avoiding.choices.map(\.label) == ["System default · MacBook Air Microphone", "AirPods Pro", "MacBook Air Microphone", "USB Mic"])
        #expect(avoiding.choices.map(\.value) == ["", "airpods", "builtin", "usb"])
        #expect(avoiding.placeholder == "Not connected · MacBook Air Microphone")
        #expect(SettingsMicrophones.menu(snapshot, avoidBluetooth: false).choices[0].label == "System default · AirPods Pro")
        #expect(SettingsMicrophones.menu(MicrophoneDevices.Snapshot(), avoidBluetooth: true).choices.map(\.label) == ["System default"])
    }

    @Test func `a microphone plan resolves to the device it records from`() {
        let snapshot = Self.airPodsDefault, route = snapshot.route(avoidBluetooth: true)
        let resolve = { (selected: String?) in
            try? MicrophoneChoice.resolve(selected: selected, inputs: snapshot.inputs, defaultUID: snapshot.defaultUID, route: route).get()
        }
        // Avoiding Bluetooth, AirPods as the default record from the built-in microphone; picked, from the AirPods.
        #expect(resolve(nil).flatMap(snapshot.resolve)?.device == 12)
        #expect(resolve("airpods").flatMap(snapshot.resolve)?.device == 11)
        #expect(snapshot.resolve(MicrophonePlan(target: .systemDefault, selection: .inUse))?.device == 11)
    }

    private static let airPodsDefault = MicrophoneDevices.Snapshot(
        inputs: [MicrophoneInput(uid: "usb", name: "USB Mic", transport: .other),
                 MicrophoneInput(uid: "airpods", name: "AirPods Pro", transport: .bluetooth),
                 MicrophoneInput(uid: "builtin", name: "MacBook Air Microphone", transport: .builtIn)],
        devices: ["usb": 10, "airpods": 11, "builtin": 12], defaultUID: "airpods", defaultDevice: 11)
}
