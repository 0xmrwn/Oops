import Foundation

/// The three local cleanups of a transcript, each behind its own switch (all off by default in the app).
public enum TranscriptCleanup {
    /// `transcript` with the enabled cleanups applied in the order fillers, formatting, symbols. With all three
    /// off it comes back byte for byte. Filler removal is language-gated by the caller (`FillerWords.applies(to:)`).
    public static func apply(_ transcript: String, fillers: Bool, formatting: Bool, symbols: Bool) -> String {
        var text = transcript
        if fillers { text = FillerWords.apply(text) }
        if formatting { text = SpokenFormatting.apply(text) }
        if symbols { text = SpokenSymbols.apply(text) }
        return text
    }
}
