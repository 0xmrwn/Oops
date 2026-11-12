import AVFoundation
import OopsCore
import Synchronization

/// The microphone as a dictation's audio source: an `AVAudioEngine` input feeding an `AVAudioSinkNode`.
/// A sink node gets the device's own render blocks (about 10 ms, 512 frames at 48 kHz) where a tap hands
/// over 100 ms at a time whatever size is asked. Its block runs on the real-time audio thread, so it only
/// mixes the block to mono into the ring: no allocation, no lock, no Swift concurrency. The engine is kept
/// between opens, stopped: restarting it delivers audio about 90 ms after the start, a new engine 130 to
/// 220 ms. Stopping it releases the microphone, and the menu bar's microphone indicator goes away.
final class DictationMicrophone: DictationAudioSource {
    private struct Engine {
        let engine = AVAudioEngine()
        var sink: AVAudioSinkNode?
        var format: AVAudioFormat?
        var ring: ObjectIdentifier?
    }

    private let access: @Sendable () -> DictationMicrophoneAccess
    // Created at the first open, after the access check: touching the input node of an app without
    // access could prompt.
    private let state = Mutex<Engine?>(nil)

    init(access: @escaping @Sendable () -> DictationMicrophoneAccess = { .current }) { self.access = access }

    func open(into ring: DictationAudioRing) throws(DictationAudioError) -> Double {
        let access = access()
        guard access == .granted else { throw .microphoneAccess(access) }
        return try state.withLock { state throws(DictationAudioError) in
            var current = state ?? Engine()
            defer { state = current }
            let engine = current.engine
            engine.stop()
            let format = engine.inputNode.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0, format.commonFormat == .pcmFormatFloat32 else { throw .noInput }
            if current.sink == nil || current.format != format || current.ring != ObjectIdentifier(ring) {
                if let sink = current.sink { engine.detach(sink) }
                let sink = AVAudioSinkNode(receiverBlock: Self.receiver(into: ring, rate: format.sampleRate))
                engine.attach(sink)
                engine.connect(engine.inputNode, to: sink, format: format)
                current.sink = sink; current.format = format; current.ring = ObjectIdentifier(ring)
            }
            engine.prepare()
            do { try engine.start() } catch { throw .failed("the microphone did not start: \(error.localizedDescription)") }
            return format.sampleRate
        }
    }

    func close() {
        state.withLock { $0?.engine.stop() }
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
