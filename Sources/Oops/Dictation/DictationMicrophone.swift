import AVFoundation
import CoreAudio
import OopsCore
import Synchronization

/// The microphone as a dictation's audio source: an `AVAudioEngine` input feeding an `AVAudioSinkNode`.
/// A sink node gets the device's own render blocks (about 10 ms, 512 frames at 48 kHz) where a tap hands
/// over 100 ms at a time whatever size is asked. Its block runs on the real-time audio thread, so it only
/// mixes the block to mono into the ring: no allocation, no lock, no Swift concurrency. The engine is kept
/// between opens, stopped: restarting it delivers audio about 90 ms after the start, a new engine 130 to
/// 220 ms. Stopping it releases the microphone, and the menu bar's microphone indicator goes away.
///
/// The engine records from the system's default input. When that input goes away or another becomes the
/// default while the engine is open, the ring ends, the engine is dropped and the loss is told. An open that
/// finds another default than the engine's last start builds a new engine too, so the next dictation always
/// records from the current default.
final class DictationMicrophone: DictationAudioSource {
    private struct Engine {
        let engine = AVAudioEngine()
        var sink: AVAudioSinkNode?
        var format: AVAudioFormat?
        var ring: DictationAudioRing?
        /// The default input when the engine last started.
        var device: AudioDeviceID?
        var isOpen = false
        var observer: any NSObjectProtocol?

        /// Stops listening; the engine is dropped next.
        func discard() {
            engine.stop()
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }

    private let access: @Sendable () -> DictationMicrophoneAccess
    // Created at the first open, after the access check: touching the input node of an app without
    // access could prompt.
    private let state = Mutex<Engine?>(nil)
    private let lost = Mutex<(@Sendable () -> Void)?>(nil)
    /// Device changes are checked here, never on the thread that posted them: the engine may post while
    /// `open` holds the state's lock.
    private let changes = DispatchQueue(label: "oops.microphone.changes")
    private let watchingDefault = Mutex(false)

    init(access: @escaping @Sendable () -> DictationMicrophoneAccess = { .current }) { self.access = access }

    func watchLoss(_ lost: @escaping @Sendable () -> Void) { self.lost.withLock { $0 = lost } }

    func open(into ring: DictationAudioRing) throws(DictationAudioError) -> Double {
        let access = access()
        guard access == .granted else { throw .microphoneAccess(access) }
        watchDefaultInput()
        let check: @Sendable () -> Void = { [weak self] in self?.inputMayHaveChanged() }
        return try state.withLock { state throws(DictationAudioError) in
            if let stale = state, stale.device != Self.defaultInput() { stale.discard(); state = nil }
            var current = state ?? Engine()
            defer { state = current }
            let engine = current.engine
            if current.observer == nil {
                current.observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                                                          queue: nil) { [changes] _ in changes.async(execute: check) }
            }
            engine.stop()
            current.isOpen = false
            let format = engine.inputNode.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0, format.commonFormat == .pcmFormatFloat32 else { throw .noInput }
            if current.sink == nil || current.format != format || current.ring !== ring {
                if let sink = current.sink { engine.detach(sink) }
                let sink = AVAudioSinkNode(receiverBlock: Self.receiver(into: ring, rate: format.sampleRate))
                engine.attach(sink)
                engine.connect(engine.inputNode, to: sink, format: format)
                current.sink = sink; current.format = format; current.ring = ring
            }
            engine.prepare()
            do { try engine.start() } catch { throw .failed("the microphone did not start: \(error.localizedDescription)") }
            current.device = Self.defaultInput(); current.isOpen = true
            return format.sampleRate
        }
    }

    func close() {
        state.withLock { state in
            state?.engine.stop()
            state?.isOpen = false
        }
    }

    /// The open engine stopped by itself, or the default input is no longer the one it started on. A spurious
    /// notification (the engine posts some as it starts) finds it running on the same input and does nothing.
    private func inputMayHaveChanged() {
        let ended: DictationAudioRing? = state.withLock { state in
            guard let current = state, current.isOpen,
                  !current.engine.isRunning || Self.defaultInput() != current.device else { return nil }
            current.discard()
            state = nil
            return current.ring
        }
        guard let ended else { return }
        ended.end()
        lost.withLock { $0 }?()
    }

    /// Listens, once, for the system's default input changing: the engine follows the default device, and
    /// may not say so itself.
    private func watchDefaultInput() {
        guard watchingDefault.withLock({ watching in
            defer { watching = true }
            return !watching
        }) else { return }
        var address = Self.defaultInputAddress
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, changes) { [weak self] _, _ in
            self?.inputMayHaveChanged()
        }
    }

    private static var defaultInputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    /// The system's default input device, or nil when there is none.
    private static func defaultInput() -> AudioDeviceID? {
        var device = AudioDeviceID(kAudioObjectUnknown), size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = defaultInputAddress
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    /// The sink node's block. Runs on the real-time audio thread: everything it reads is captured up front.
    private static func receiver(into ring: DictationAudioRing, rate: Double) -> AVAudioSinkNodeReceiverBlock {
        let clock = CaptureInstant.HostClock()
        let nanosPerFrame = 1e9 / rate
        return { timestamp, frameCount, bufferList in
            let frames = Int(frameCount)
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
            let start = clock.instant(ticks: timestamp.pointee.mHostTime)
            let through = start + .nanoseconds(Int64(Double(frames) * nanosPerFrame))
            if buffers.count == 1, let data = buffers[0].mData?.assumingMemoryBound(to: Float.self) {
                // One buffer: mono, or interleaved channels.
                let channels = max(Int(buffers[0].mNumberChannels), 1)
                ring.write(frames: frames, capturedThrough: through) { frame in
                    var sum: Float = 0
                    for channel in 0 ..< channels { sum += data[frame * channels + channel] }
                    return sum / Float(channels)
                }
            } else if buffers.count > 1 {
                // One buffer per channel.
                let channels = buffers.count
                ring.write(frames: frames, capturedThrough: through) { frame in
                    var sum: Float = 0
                    for channel in 0 ..< channels { sum += buffers[channel].mData?.assumingMemoryBound(to: Float.self)[frame] ?? 0 }
                    return sum / Float(channels)
                }
            }
            return noErr
        }
    }
}
