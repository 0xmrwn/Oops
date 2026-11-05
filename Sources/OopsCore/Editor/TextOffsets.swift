import Foundation

/// Offsets an app reports through Accessibility, which can be anything: negative, past the end, or
/// NSNotFound (an Int near its maximum, which overflows when a length is added). Every range read
/// from an editor goes through here before any arithmetic.
public enum TextOffsets {
    /// No draft Oops handles comes near this many UTF-16 units.
    public static let limit = 10_000_000

    /// The range, if it is one: non-negative, and ending within `limit`.
    public static func plausible(location: Int, length: Int) -> NSRange? {
        guard location >= 0, length >= 0, location <= limit, length <= limit - location else { return nil }
        return NSRange(location: location, length: length)
    }

    /// The range between two reported indexes, counted from `base`.
    public static func between(_ lower: Int, _ upper: Int, from base: Int) -> NSRange? {
        guard base >= 0, base <= limit, lower >= base, upper >= lower, upper <= limit else { return nil }
        return plausible(location: lower - base, length: upper - lower)
    }

    /// Where `needle` sits in `text` nearest to `location`, at most `within` units away: where a
    /// selection that came out a few units off really landed.
    public static func nearest(_ needle: String, in text: String, to location: Int, within: Int) -> Int? {
        let hay = Array(text.utf16), want = Array(needle.utf16)
        guard !want.isEmpty, want.count <= hay.count, location >= 0, location <= limit, within >= 0, within <= limit else { return nil }
        let lower = max(0, location - within), upper = min(hay.count - want.count, location + within)
        guard lower <= upper else { return nil }
        let candidates = lower...upper
        return candidates.filter { Array(hay[$0..<($0 + want.count)]) == want }.min { abs($0 - location) < abs($1 - location) }
    }

    /// A larger offset correction needs an unambiguous observation, not another repeated fragment.
    public static func uniqueOccurrence(_ needle: String, in text: String, to location: Int, within: Int) -> Int? {
        guard let found = nearest(needle, in: text, to: location, within: within) else { return nil }
        let source = text as NSString
        guard source.range(of: needle, options: .literal).location == found,
              source.range(of: needle, options: [.literal, .backwards]).location == found else { return nil }
        return found
    }
}
