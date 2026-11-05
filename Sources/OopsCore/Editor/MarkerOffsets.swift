import Foundation

/// A word's range in a second reading of the same editor. Gecko's value can flatten breaks,
/// pad chips, and spell an emoji whose markers count one object. Only those differences may
/// shift a word; changed letters or punctuation cannot justify selecting somewhere else.
public enum MarkerOffsets {
    public static func range(_ range: NSRange, from value: String, to markers: String) -> NSRange? {
        guard TextOffsets.plausible(location: range.location, length: range.length) != nil,
              NSMaxRange(range) <= value.utf16.count, range.length > 0 else { return nil }
        let source = value as NSString, target = markers as NSString
        var shift = 0
        guard let hunks = differences(value, markers) else { return nil }
        for hunk in hunks {
            guard NSIntersectionRange(hunk.before, range).length == 0,
                  !(hunk.before.length == 0 && hunk.before.location > range.location && hunk.before.location < NSMaxRange(range)) else { return nil }
            if NSMaxRange(hunk.before) <= range.location { shift += hunk.after.length - hunk.before.length }
        }
        guard let mapped = TextOffsets.plausible(location: range.location + shift, length: range.length),
              NSMaxRange(mapped) <= target.length,
              sameText(source.substring(with: range), target.substring(with: mapped)) else { return nil }
        return mapped
    }
    /// For choosing a capture reading, where the user's selection can span padding differences.
    /// This is not paste confirmation: a word range itself must still remain unchanged.
    public static func compatible(_ value: String, _ markers: String) -> Bool { differences(value, markers) != nil }

    private static func differences(_ value: String, _ markers: String) -> [WordDiff.Hunk]? {
        let source = value as NSString, target = markers as NSString
        func padding(_ character: Character) -> Bool {
            character.isWhitespace || ["\u{FEFF}", "\u{200B}", "\u{2060}"].contains(character)
        }
        // String equality folds canonical Unicode variants; marker positions count exact UTF-16.
        let hunks = WordDiff(before: value, after: markers, key: { $0.utf16.map { String($0) }.joined(separator: ",") }).hunks
        for hunk in hunks {
            let before = source.substring(with: hunk.before), after = target.substring(with: hunk.after)
            let spaces = before.allSatisfy(padding) && after.allSatisfy(padding)
            let atoms = after.contains("\u{FFFC}") && after.allSatisfy { padding($0) || $0 == "\u{FFFC}" }
                && before.allSatisfy { padding($0) || $0 == "\u{FFFC}" || $0.unicodeScalars.contains { $0.properties.isEmojiPresentation } }
            guard spaces || atoms else { return nil }
        }
        return hunks
    }
}
