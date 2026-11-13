import Foundation

/// How the dictation drop shows a voice. Every kind reads the same input: the drop's state, and a loudness
/// from 0 to 1 already smoothed (fast attack, slow release) at the display's rate. The raw values are what
/// Settings stores under `defaultsKey`.
public enum DictationVisualizer: String, CaseIterable, Sendable {
    /// A dot scope.
    case hex
    /// The last second of loudness, as mirrored bars scrolling away from the newest.
    case wave
    /// Rings sent out from a small core on each syllable's onset.
    case ripple

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

/// Rings for the ripple: one on each onset (a rise in loudness over its recent level), so syllables send out
/// rings at the rate they are spoken while a held level sends none. A ring's amplitude is the peak of the
/// attack that sent it.
public struct RippleEmitter: Sendable, Equatable {
    public struct Ring: Sendable, Equatable {
        public var born: Double
        public var amplitude: Float
    }

    /// Seconds a ring lives.
    public static let lifetime = 0.9
    /// Quieter than this sends nothing: room noise left by the smoothing.
    public static let floor: Float = 0.1
    /// How far the level must rise over its recent level to count as an onset.
    public static let rise: Float = 0.08
    /// The shortest gap between rings: speech is at most about seven syllables a second.
    public static let refractory = 0.14
    public static let capacity = 8
    /// Seconds the recent level takes to follow loudness: slower than a syllable's attack, so the attack shows
    /// as a rise.
    static let follow = 0.15

    public private(set) var rings: [Ring] = []
    private var recent: Float = 0
    private var lastTime: Double?
    private var lastRing = -Double.infinity

    public init() { rings.reserveCapacity(Self.capacity) }

    public mutating func step(time: Double, level: Float) {
        let level = min(max(level, 0), 1)
        rings.removeAll { time - $0.born >= Self.lifetime }
        let dt = lastTime.map { max(time - $0, 0) } ?? 0
        lastTime = time
        // An onset is caught early in its attack: the ring takes the level the attack goes on to reach.
        if let last = rings.indices.last, time - rings[last].born < Self.refractory, level > rings[last].amplitude {
            rings[last].amplitude = level
            recent = level
        } else if level >= Self.floor, level - recent >= Self.rise, time - lastRing >= Self.refractory {
            if rings.count == Self.capacity { rings.removeFirst() }
            rings.append(Ring(born: time, amplitude: level))
            lastRing = time
            // Re-armed only by a further rise, or by a dip and a new attack.
            recent = level
        } else {
            recent += (level - recent) * Float(1 - exp(-dt / Self.follow))
        }
    }

    /// No rings, as a new recording starts.
    public mutating func reset() { self = Self() }
}
