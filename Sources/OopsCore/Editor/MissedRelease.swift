import Foundation

/// A held chord's release that may never come. Another app's event tap can swallow the key-up, and the
/// hotkey's release with it: the chord would then read as held for good, every later press of it would be
/// dropped as a repeat, and a dictation it started would never end. While the chord is held its key is
/// sampled every `interval`; once the key has read up `confirmations` samples in a row the release is
/// inferred, at the first of them, so a hold is still measured to when the key really came up.
public struct MissedRelease<Instant> {
    public static var interval: Duration { .milliseconds(50) }
    /// Two samples: a real release, delivered a moment after the key comes up, wins over the inferred one.
    public static var confirmations: Int { 2 }

    private var upSince: Instant?
    private var upCount = 0

    public init() {}

    /// One sample of the chord's key. Returns when it came up once that is settled, else nil.
    public mutating func sample(keyDown: Bool, at instant: Instant) -> Instant? {
        guard !keyDown else { upSince = nil; upCount = 0; return nil }
        if upSince == nil { upSince = instant }
        upCount += 1
        return upCount >= Self.confirmations ? upSince : nil
    }
}

extension MissedRelease: Sendable where Instant: Sendable {}
