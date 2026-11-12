import AVFoundation
import OopsCore
import Synchronization

/// A WAV file that stands in for the microphone, so tests drive the real recorder, ring and converter
/// without recording anyone. After Hex's audio fixture (`src/audio/fixture.rs` at 1b82cc0): the file plays
/// from its start at each open, mixed to mono, in 10 ms blocks, each stamped with when its last sample was
/// due, as a device stamps its samples' own time. At real-time pace it loops, and a late wake delivers a
/// block late but never moves its stamp. Immediate pace plays the file once as fast as the ring takes it,
/// stamped from a given instant, so a test can place presses and releases exactly on its timeline.
final class DictationAudioFile: DictationAudioSource {
    enum Pace: Sendable {
        case realTime
        case immediate(from: CaptureInstant)
    }

    /// Blocks per second, as a device's 10 ms period delivers them.
    static let blocksPerSecond = 100

    let url: URL
    let pace: Pace
    private let decoded = Mutex<(samples: [Float], rate: Double)?>(nil)
    private let player = Mutex<Player?>(nil)

    init(url: URL, pace: Pace = .realTime) { self.url = url; self.pace = pace }

    /// The file's samples mixed to mono, and their rate.
    static func read(_ url: URL) throws(DictationAudioError) -> (samples: [Float], rate: Double) {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch { throw .unreadableFile("could not open \(url.lastPathComponent): \(error.localizedDescription)") }
        let format = file.processingFormat, frames = AVAudioFrameCount(file.length)
        guard frames >= AVAudioFrameCount(format.sampleRate) / AVAudioFrameCount(blocksPerSecond),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)
        else { throw .unreadableFile("\(url.lastPathComponent) holds no audio") }
        do { try file.read(into: buffer) } catch { throw .unreadableFile("could not read \(url.lastPathComponent): \(error.localizedDescription)") }
        guard let channels = buffer.floatChannelData else { throw .unreadableFile("\(url.lastPathComponent) is not PCM") }
        let count = Int(format.channelCount), length = Int(buffer.frameLength)
        let mono = (0 ..< length).map { frame in (0 ..< count).reduce(Float(0)) { $0 + channels[$1][frame] } / Float(count) }
        return (mono, format.sampleRate)
    }

    func open(into ring: DictationAudioRing) throws(DictationAudioError) -> Double {
        close()
        let (samples, rate) = try decoded.withLock { cached throws(DictationAudioError) in
            if let cached { return cached }
            let read = try Self.read(url)
            cached = read
            return read
        }
        let player = Player()
        self.player.withLock { $0 = player }
        let blockFrames = Int(rate) / Self.blocksPerSecond
        let pace = pace
        let thread = Thread {
            defer { player.done.signal() }
            let period = Duration.seconds(1) / Self.blocksPerSecond
            let started = ContinuousClock.now
            let origin: CaptureInstant = switch pace {
            case .realTime: .now()
            case let .immediate(from): from
            }
            var at = 0, block = 1
            while !player.stopped.load(ordering: .acquiring) {
                var out: [Float] = []
                switch pace {
                case .realTime:
                    // Paced against the start, so a late wake never drifts.
                    let wait = (started + period * block) - .now
                    if wait > .zero { Thread.sleep(forTimeInterval: Double(wait.components.seconds) + Double(wait.components.attoseconds) * 1e-18) }
                    while out.count < blockFrames {
                        let take = min(blockFrames - out.count, samples.count - at)
                        out.append(contentsOf: samples[at ..< at + take])
                        at = (at + take) % samples.count
                    }
                case .immediate:
                    guard at < samples.count else { ring.end(); return }
                    out = Array(samples[at ..< min(at + blockFrames, samples.count)])
                    at += out.count
                }
                let through = origin + .nanoseconds(Int64((block - 1) * blockFrames + out.count) * 1_000_000_000 / Int64(rate))
                while !ring.write(frames: out.count, capturedThrough: through, sample: { out[$0] }) {
                    // Only a file waits for room; at real-time pace a full ring drops the block, as the microphone's would.
                    guard case .immediate = pace, !player.stopped.load(ordering: .acquiring) else { break }
                    Thread.sleep(forTimeInterval: 0.001)
                }
                block += 1
            }
        }
        thread.name = "Dictation audio file"
        thread.start()
        return rate
    }

    func close() {
        guard let player = player.withLock({ player in defer { player = nil }; return player }) else { return }
        player.stopped.store(true, ordering: .releasing)
        player.done.wait()
    }
}

/// One play of the file: the thread stops once `stopped` is set, and signals `done` as it exits.
private final class Player: Sendable {
    let stopped = Atomic<Bool>(false)
    let done = DispatchSemaphore(value: 0)
}
