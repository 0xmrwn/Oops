import Foundation

/// The maths behind the loudness a recording shows: a block's level, mapped to 0 to 1 and smoothed so a
/// visualizer neither flickers nor lags.
public enum DictationLoudness {
    /// The block level, in dBFS, that reads 0 and the one that reads 1. Speech into a laptop microphone
    /// spans most of this range; the floor sits above room noise.
    public static let floorDBFS: Float = -50
    public static let ceilingDBFS: Float = -10
    /// Time constants of the smoothing, in seconds: the level jumps up fast and falls back slowly.
    public static let attack: Float = 0.03
    public static let release: Float = 0.22
    /// Below this the smoothed level snaps to 0, so a stopped input comes to rest.
    static let rest: Float = 0.002

    /// A block's RMS level with its mean removed, as the silence gate reads it, from the sums the audio
    /// thread takes in its one pass over the block.
    public static func rms(sum: Float, sumOfSquares: Float, count: Int) -> Float {
        guard count > 0 else { return 0 }
        let n = Float(count), mean = sum / n
        return max(sumOfSquares / n - mean * mean, 0).squareRoot()
    }

    /// `rms` (linear, full scale 1) as 0 to 1: linear in dB between `floorDBFS` and `ceilingDBFS`.
    public static func normalized(rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let decibels = 20 * log10(rms)
        return min(max((decibels - floorDBFS) / (ceilingDBFS - floorDBFS), 0), 1)
    }

    /// One step of the smoothing, `dt` seconds after the last: toward `target` along an exponential, with the
    /// attack's time constant going up and the release's going down.
    public static func smoothed(_ current: Float, toward target: Float, dt: Float) -> Float {
        let tau = target > current ? attack : release
        let next = current + (target - current) * (1 - exp(-max(dt, 0) / tau))
        return target == 0 && next < rest ? 0 : next
    }
}
