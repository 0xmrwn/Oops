import Foundation

/// How the dictation drop shows a voice. Every kind reads the same input: the drop's state, and a loudness
/// from 0 to 1 already smoothed (fast attack, slow release) at the display's rate. The raw values are what
/// Settings stores under `defaultsKey`.
public enum DictationVisualizer: String, CaseIterable, Sendable {
    /// A dot scope.
    case hex
    /// A few hairline strands fanning out from one line as the voice is heard.
    case string
    /// The voice as it was heard, as mirrored bars scrolling away from the newest.
    case wave

    public static let defaultsKey = "DictationVisualizer"
    public static let standard = Self.hex

    public static func stored(in defaults: UserDefaults = .standard) -> Self {
        defaults.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? standard
    }
}

/// Recent loudness at a fixed rate, newest first, for a waveform that shows the rhythm of speech. Each sample
/// keeps the loudest level seen during its interval, so a syllable shorter than one interval still shows.
public struct LoudnessHistory: Sendable, Equatable {
    public let capacity: Int
    /// Seconds between samples.
    public let interval: Double
    private var samples: [Float]
    /// Where the newest sample is in `samples`.
    private var head = 0
    private var newestAt: Double?
    /// The loudest level since the newest sample was taken: the next sample's value.
    private var pending: Float = 0
    /// How far time has moved toward the next sample, 0 up to 1: a drawing scrolls by it, so bars glide
    /// rather than jump an interval at a time.
    public private(set) var progress: Double = 0

    public init(capacity: Int, interval: Double) {
        self.capacity = max(capacity, 1); self.interval = interval
        samples = Array(repeating: 0, count: self.capacity)
    }

    /// The sample `age` intervals old: 0 is the newest; past the capacity, silence.
    public subscript(age: Int) -> Float {
        guard age >= 0, age < capacity else { return 0 }
        return samples[(head - age + capacity) % capacity]
    }

    /// Every sample and the level still to come are silent.
    public var isSilent: Bool { pending == 0 && !samples.contains { $0 > 0 } }

    /// Takes `level` at `time`. Each whole interval since the newest sample records the loudest level seen
    /// during it; `level` itself starts the next one. A time at or before the last only feeds the next sample,
    /// so a view evaluated twice in a frame records nothing twice. A gap (frames not drawn, or a caller that
    /// stopped feeding silence) records what was last heard, silence included.
    public mutating func advance(to time: Double, level: Float) {
        let level = min(max(level, 0), 1)
        guard let newestAt else { newestAt = time; pending = level; return }
        let steps = Int(((time - newestAt) / interval).rounded(.down))
        if steps > 0 {
            for _ in 0..<min(steps, capacity) { push(pending) }
            self.newestAt = steps > capacity ? time : newestAt + Double(steps) * interval
            pending = level
        } else {
            pending = max(pending, level)
        }
        progress = min(max((time - (self.newestAt ?? time)) / interval, 0), 1)
    }

    /// The level the next sample will take: the loudest since the newest one.
    public var next: Float { pending }

    /// Back to silence, as a new recording starts.
    public mutating func reset() {
        for index in samples.indices { samples[index] = 0 }
        head = 0; newestAt = nil; pending = 0; progress = 0
    }

    private mutating func push(_ value: Float) {
        head = (head + 1) % capacity
        samples[head] = value
    }
}
