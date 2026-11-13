import Foundation

// The capture timeline, ported from Hex (github.com/anomalyco/hex, `src/audio/instant.rs` at 1b82cc0; MIT,
// Copyright (c) 2026 Christopher Langton).

/// A point on the clock microphone timestamps and shortcut events share: host uptime, in nanoseconds
/// (the clock `mach_absolute_time` counts).
public struct CaptureInstant: Comparable, Hashable, Sendable, CustomStringConvertible {
    public static let zero = CaptureInstant(nanoseconds: 0)
    public let nanoseconds: UInt64

    public init(nanoseconds: UInt64) { self.nanoseconds = nanoseconds }

    public var description: String { "\(Double(nanoseconds) / 1e9) s" }

    public static func < (lhs: CaptureInstant, rhs: CaptureInstant) -> Bool { lhs.nanoseconds < rhs.nanoseconds }

    public static func + (instant: CaptureInstant, duration: Duration) -> CaptureInstant {
        CaptureInstant(nanoseconds: instant.nanoseconds &+ UInt64(clamping: duration.nanoseconds))
    }

    public static func += (instant: inout CaptureInstant, duration: Duration) { instant = instant + duration }

    public func checkedSub(_ duration: Duration) -> CaptureInstant? {
        let nanos = UInt64(clamping: duration.nanoseconds)
        return nanoseconds >= nanos ? CaptureInstant(nanoseconds: nanoseconds - nanos) : nil
    }

    /// How long after `earlier` this is; nil when it is before it.
    public func checkedDuration(since earlier: CaptureInstant) -> Duration? {
        nanoseconds >= earlier.nanoseconds ? .nanoseconds(Int64(clamping: nanoseconds - earlier.nanoseconds)) : nil
    }

    /// How long after `earlier` this is, or zero when it is before it.
    public func duration(since earlier: CaptureInstant) -> Duration { checkedDuration(since: earlier) ?? .zero }

    /// `frames` samples at `sampleRate` earlier, or this instant when that would fall before zero.
    func subFrames(_ frames: Int, sampleRate: Int) -> CaptureInstant {
        checkedSub(durationForFrames(frames, sampleRate: sampleRate)) ?? self
    }
}

/// How long `frames` samples last at `sampleRate`, to the nanosecond below.
func durationForFrames(_ frames: Int, sampleRate: Int) -> Duration {
    .nanoseconds(Int64(frames) * 1_000_000_000 / Int64(sampleRate))
}

/// How many samples `duration` holds at `sampleRate`, rounded to the nearest.
func samplesFor(_ duration: Duration, sampleRate: Int) -> Int {
    Int((duration.seconds * Double(sampleRate)).rounded())
}

/// Milliseconds from `earlier` to `later`, negative when `later` comes first.
func signedMilliseconds(_ later: CaptureInstant, _ earlier: CaptureInstant) -> Int64 {
    (Int64(clamping: later.nanoseconds) - Int64(clamping: earlier.nanoseconds)) / 1_000_000
}

extension Duration {
    var nanoseconds: Int64 { components.seconds * 1_000_000_000 + components.attoseconds / 1_000_000_000 }
    var seconds: Double { Double(nanoseconds) / 1e9 }
    /// `self - other`, or zero when `other` is longer: a Duration never goes negative on the timeline.
    func saturatingSub(_ other: Duration) -> Duration { Swift.max(.zero, self - other) }
}
