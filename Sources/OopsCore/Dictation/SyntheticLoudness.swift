import Foundation

/// A speech-like loudness, 0 to 1, as a function of time, looping every `period` seconds: silence, a phrase
/// spoken at about five syllables a second with pauses between words, a second phrase, a loud burst, a phrase
/// trailing off, then silence again. It stands in for the microphone so the dictation drop can be watched and
/// recorded without one. The same time always gives the same level.
public enum SyntheticLoudness {
    public static let period = 12.0

    /// The level at `time` seconds, at the smoothing the live feed has: each syllable attacks in 40 ms and
    /// releases over about a tenth of a second.
    public static func level(at time: Double) -> Float {
        let t = time - (time / period).rounded(.down) * period
        var level = 0.0
        for syllable in syllables where syllable.start <= t {
            let since = t - syllable.start
            if since > 0.8 { continue }
            let attack = smoothstep(since / 0.04)
            let hold = syllable.length * 0.35
            let release = since <= hold ? 1 : exp(-(since - hold) / 0.09)
            level = max(level, syllable.peak * attack * release)
        }
        // The tail of the last release would never quite reach zero; a pause should.
        return level < 0.005 ? 0 : Float(min(level, 1))
    }

    /// The phases, for a lab to name what it is showing.
    public static let silenceEnds = 2.0, burstStarts = 7.6, burstPeak = 7.64, fadeEnds = 9.6

    private struct Syllable { let start, length, peak: Double }

    /// Words as (start, syllables, loudness); each syllable lasts about a fifth of a second.
    private static let words: [(Double, Int, Double)] = [
        // "so I was thinking about it", then a breath.
        (2.0, 3, 0.55), (2.75, 2, 0.62), (3.3, 4, 0.5),
        // "and we could move the meeting to friday".
        (4.75, 2, 0.6), (5.25, 3, 0.66), (5.95, 2, 0.48), (6.45, 3, 0.58),
        // A laugh or a stressed word.
        (7.6, 2, 1.0),
        // "if that works for you", trailing off.
        (8.25, 2, 0.5), (8.7, 2, 0.32), (9.1, 2, 0.18),
    ]

    private static let syllables: [Syllable] = {
        var syllables: [Syllable] = []
        var index = 0
        for (start, count, loudness) in words {
            var at = start
            for position in 0..<count {
                // Fixed variation in length and stress, the way no two syllables match.
                let jitter = fraction(sin(Double(index) * 12.9898) * 43758.5453)
                let length = 0.17 + 0.05 * jitter
                let stress = loudness == 1 ? 1 : loudness * (0.78 + 0.3 * jitter) * (position == 0 ? 1.08 : 1)
                syllables.append(Syllable(start: at, length: length, peak: min(stress, 1)))
                at += length; index += 1
            }
        }
        return syllables
    }()

    private static func fraction(_ x: Double) -> Double { x - x.rounded(.down) }
    private static func smoothstep(_ x: Double) -> Double {
        let x = min(max(x, 0), 1)
        return x * x * (3 - 2 * x)
    }
}
