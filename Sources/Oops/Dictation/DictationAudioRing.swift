import OopsCore
import Synchronization

/// Hands audio from the thread that captures it to the recorder that drains it, with one writer and one
/// reader. The microphone writes from the real-time audio thread, which must never wait: storage is
/// allocated up front, positions are atomics, and a block that does not fit is dropped and counted rather
/// than waited for. Samples and their block stamps live in two power-of-two rings; a block is published
/// only once its samples are written.
final class DictationAudioRing: @unchecked Sendable {
    /// About 5 s of 48 kHz audio: the recorder drains every 10 ms, so only a stall that long loses audio.
    static let defaultSampleCapacity = 1 << 18
    static let defaultBlockCapacity = 1 << 11

    private let samples: UnsafeMutablePointer<Float>
    private let blockFrames: UnsafeMutablePointer<Int>
    private let blockThrough: UnsafeMutablePointer<UInt64>
    private let sampleCapacity: Int
    private let blockCapacity: Int
    // Positions only grow; an index into a ring is the position masked by its capacity.
    private let sampleWrite = Atomic<Int>(0)
    private let sampleRead = Atomic<Int>(0)
    private let blockWrite = Atomic<Int>(0)
    private let blockRead = Atomic<Int>(0)
    private let dropped = Atomic<Int>(0)
    private let ended = Atomic<Bool>(false)
    /// The newest block's RMS level, as `Float` bits: a single value the main actor samples at display rate,
    /// where the blocks themselves go to the recorder.
    private let level = Atomic<UInt32>(0)

    init(sampleCapacity: Int = defaultSampleCapacity, blockCapacity: Int = defaultBlockCapacity) {
        precondition(sampleCapacity.nonzeroBitCount == 1 && blockCapacity.nonzeroBitCount == 1, "ring capacities are powers of two")
        self.sampleCapacity = sampleCapacity; self.blockCapacity = blockCapacity
        samples = .allocate(capacity: sampleCapacity); samples.initialize(repeating: 0, count: sampleCapacity)
        blockFrames = .allocate(capacity: blockCapacity); blockFrames.initialize(repeating: 0, count: blockCapacity)
        blockThrough = .allocate(capacity: blockCapacity); blockThrough.initialize(repeating: 0, count: blockCapacity)
    }

    deinit { samples.deallocate(); blockFrames.deallocate(); blockThrough.deallocate() }

    /// Writer: adds a block of `frames` samples, `sample(i)` each, captured through `capturedThrough`.
    /// Never blocks or allocates; returns false, counting the frames as dropped, when the block does not fit.
    @discardableResult
    func write(frames: Int, capturedThrough: CaptureInstant, sample: (Int) -> Float) -> Bool {
        let write = sampleWrite.load(ordering: .relaxed), block = blockWrite.load(ordering: .relaxed)
        guard frames > 0, frames <= sampleCapacity - (write - sampleRead.load(ordering: .acquiring)),
              block - blockRead.load(ordering: .acquiring) < blockCapacity
        else {
            if frames > 0 { dropped.add(frames, ordering: .relaxed) }
            return false
        }
        let mask = sampleCapacity - 1
        var sum: Float = 0, squares: Float = 0
        for index in 0 ..< frames {
            let value = sample(index)
            samples[(write + index) & mask] = value
            sum += value; squares += value * value
        }
        level.store(DictationLoudness.rms(sum: sum, sumOfSquares: squares, count: frames).bitPattern, ordering: .relaxed)
        blockFrames[block & (blockCapacity - 1)] = frames
        blockThrough[block & (blockCapacity - 1)] = capturedThrough.nanoseconds
        sampleWrite.store(write + frames, ordering: .releasing)
        blockWrite.store(block + 1, ordering: .releasing)
        return true
    }

    /// Writer: no more audio will come (a file played to its end).
    func end() { level.store(0, ordering: .relaxed); ended.store(true, ordering: .releasing) }

    /// Any thread: the newest block's RMS level (linear, full scale 1); 0 before the first block and after the end.
    var latestLevel: Float { Float(bitPattern: level.load(ordering: .relaxed)) }

    /// Reader: hands over every published block, oldest first, freeing its space before `body` runs.
    func drain(_ body: ([Float], CaptureInstant) -> Void) {
        let published = blockWrite.load(ordering: .acquiring)
        var block = blockRead.load(ordering: .relaxed), read = sampleRead.load(ordering: .relaxed)
        let mask = sampleCapacity - 1
        while block < published {
            let frames = blockFrames[block & (blockCapacity - 1)]
            let through = CaptureInstant(nanoseconds: blockThrough[block & (blockCapacity - 1)])
            let start = read
            let audio = [Float](unsafeUninitializedCapacity: frames) { buffer, count in
                for index in 0 ..< frames { buffer[index] = samples[(start + index) & mask] }
                count = frames
            }
            read += frames; block += 1
            sampleRead.store(read, ordering: .releasing)
            blockRead.store(block, ordering: .releasing)
            body(audio, through)
        }
    }

    /// Reader: the writer has ended and every block it wrote has been drained.
    var isEnded: Bool { ended.load(ordering: .acquiring) && blockRead.load(ordering: .relaxed) == blockWrite.load(ordering: .acquiring) }

    /// Frames dropped because the reader fell behind.
    var droppedFrames: Int { dropped.load(ordering: .relaxed) }

    /// Empties the ring. Only while no writer is open.
    func reset() {
        sampleRead.store(sampleWrite.load(ordering: .acquiring), ordering: .releasing)
        blockRead.store(blockWrite.load(ordering: .acquiring), ordering: .releasing)
        ended.store(false, ordering: .releasing)
        level.store(0, ordering: .relaxed)
        dropped.store(0, ordering: .relaxed)
    }
}
