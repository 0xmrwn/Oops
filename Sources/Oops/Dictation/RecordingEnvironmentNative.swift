import AppKit
import CoreAudio
import OopsCore
import OSLog

// The macOS adapters of Hex's recording environment at v3.4.0 (MIT, github.com/anomalyco/hex): the CoreAudio
// output of `src/audio/recording_environment.rs` and `src/audio/recording_environment/ducking.rs`, and its
// AppleScript media pause. See THIRD_PARTY_NOTICES.md.

extension RecordingEnvironmentController {
    /// The environment that really changes this Mac's output and media.
    static func native() -> RecordingEnvironmentController {
        RecordingEnvironmentController { effect in
            switch effect {
            case .mute: OutputMute.start(CoreAudioVolume.mainVolume())
            case .duck: OutputDuckingGuard.start(factor: Float(DictationAudioSettings.lowerLevel())) { CoreAudioVolume.channels() }
            case .pause: PausedMedia.start(SystemMediaPlayers())
            }
        }
    }
}

/// Volumes of the default output device, each an element of one property.
final class CoreAudioVolume: OutputVolume {
    private let device: AudioObjectID
    private let selector: AudioObjectPropertySelector
    private let elements: [AudioObjectPropertyElement]

    private init(device: AudioObjectID, selector: AudioObjectPropertySelector, elements: [AudioObjectPropertyElement]) {
        self.device = device; self.selector = selector; self.elements = elements
    }

    /// The device's virtual main volume, which Mute sets to zero.
    static func mainVolume() -> CoreAudioVolume? {
        guard let device = defaultOutput() else { return nil }
        let main = CoreAudioVolume(device: device, selector: virtualMainVolume, elements: [kAudioObjectPropertyElementMain])
        return main.read() == nil ? nil : main
    }

    /// The device's channel volumes, or its master volume when channels cannot be set separately.
    static func channels() -> CoreAudioVolume? {
        guard let device = defaultOutput(), let channels = channelCount(device) else { return nil }
        let separate = CoreAudioVolume(device: device, selector: kAudioDevicePropertyVolumeScalar, elements: Array(1 ... max(channels, 1)))
        if channels > 0, separate.writable, separate.read() != nil { return separate }
        // A master write must not destroy a readable balance we cannot restore individually.
        if channels > 0, separate.elements.contains(where: { separate.value(of: $0) != nil }) { return nil }
        let whole = CoreAudioVolume(device: device, selector: kAudioDevicePropertyVolumeScalar, elements: [kAudioObjectPropertyElementMain])
        return whole.writable && whole.read() != nil ? whole : nil
    }

    /// `kAudioHardwareServiceDeviceProperty_VirtualMainVolume`, by its code as Hex names it.
    private static let virtualMainVolume: AudioObjectPropertySelector = 0x766D_7663 // 'vmvc'

    private static func defaultOutput() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(0), size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != 0 ? device : nil
    }

    /// The output channels across the device's streams, read from its stream configuration.
    private static func channelCount(_ device: AudioObjectID) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var bytes: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &bytes) == noErr,
              (UInt32(MemoryLayout<AudioBufferList>.size) ... 65_536).contains(bytes) else { return nil }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(bytes), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        var read = bytes
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &read, storage) == noErr,
              read <= bytes, Int(read) >= MemoryLayout<AudioBufferList>.size else { return nil }
        let list = storage.assumingMemoryBound(to: AudioBufferList.self)
        let count = Int(list.pointee.mNumberBuffers)
        guard let offset = MemoryLayout<AudioBufferList>.offset(of: \.mBuffers),
              offset + count * MemoryLayout<AudioBuffer>.stride <= Int(read) else { return nil }
        var channels: UInt32 = 0
        for buffer in UnsafeMutableAudioBufferListPointer(list) {
            let (sum, overflow) = channels.addingReportingOverflow(buffer.mNumberChannels)
            guard !overflow else { return nil }
            channels = sum
        }
        return channels <= 256 ? channels : nil
    }

    private func address(_ element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeOutput, mElement: element)
    }

    private var writable: Bool {
        elements.allSatisfy { element in
            var address = address(element), settable: DarwinBoolean = false
            return AudioObjectIsPropertySettable(device, &address, &settable) == noErr && settable.boolValue
        }
    }

    private func value(of element: AudioObjectPropertyElement) -> Float? {
        var address = address(element), value: Float = 0, size = UInt32(MemoryLayout<Float>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr,
              size == UInt32(MemoryLayout<Float>.size), value.isFinite, (0 ... 1).contains(value) else { return nil }
        return value
    }

    func read() -> [Float]? {
        let values = elements.compactMap(value(of:))
        return values.count == elements.count ? values : nil
    }

    func write(_ values: [Float]) -> Bool {
        var success = true
        for (element, value) in zip(elements, values) {
            var address = address(element), value = value
            success = AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float>.size), &value) == noErr && success
        }
        return success
    }
}

/// Music, Spotify and VLC as macOS reports them running, told through `osascript` as Hex does. Only players Oops
/// may already automate count: asking would open the Automation dialog in the middle of a dictation.
final class SystemMediaPlayers: MediaPlayers {
    private static let log = Logger(subsystem: "dev.0xmrwn.oops", category: "Dictation")

    func running() -> Set<MediaPlayer> {
        let running = NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier.flatMap(MediaPlayer.init(bundleID:)) }
        return Set(running.filter(Self.mayAutomate))
    }

    private static func mayAutomate(_ player: MediaPlayer) -> Bool {
        guard let target = NSAppleEventDescriptor(bundleIdentifier: player.bundleID).aeDesc else { return false }
        return AEDeterminePermissionToAutomateTarget(target, typeWildCard, typeWildCard, false) == noErr
    }

    func run(_ script: String) -> String? {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            Self.log.notice("media script failed status=\(process.terminationStatus, privacy: .public)")
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }
}
