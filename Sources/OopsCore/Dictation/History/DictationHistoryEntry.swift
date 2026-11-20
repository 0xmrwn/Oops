import Foundation

// One dictation kept in history, ported from Hex (github.com/anomalyco/hex, `src/history.rs` at v3.4.0 and `recent_title`
// in `src/macos_rune/status_item.rs`; MIT, Copyright (c) 2026 Christopher Langton). See THIRD_PARTY_NOTICES.md.
// Left out: the raw transcript (Oops keeps only the text a dictation produced), kind, processing, timings, versions
// and recordings (Oops keeps no audio and no earlier transcripts). Added: the app's bundle ID, for its icon.

/// One finished dictation in history.
public struct DictationHistoryEntry: Codable, Equatable, Identifiable, Sendable {
    public let id: Int
    /// Milliseconds since 1970, as Hex's `timestamp_ms`.
    public let timestampMs: Int
    /// The text the dictation produced (Hex's `final_text`).
    public var text: String
    /// The app's name, as Hex's `application`.
    public var application: String?
    public var bundleID: String?
    /// The speech model's name.
    public var model: String?
    public var language: String?

    public init(id: Int, timestampMs: Int, text: String, application: String? = nil, bundleID: String? = nil, model: String? = nil, language: String? = nil) {
        self.id = id; self.timestampMs = timestampMs; self.text = text
        self.application = application; self.bundleID = bundleID; self.model = model; self.language = language
    }

    public var date: Date { Date(timeIntervalSince1970: Double(timestampMs) / 1_000) }

    var textBytes: Int { text.utf8.count }

    /// One menu line: Hex's `recent_title` (whitespace and line breaks collapsed) cut by its `menu_title` to 48
    /// characters ending in "…". Hex counts Unicode scalars; this counts characters, so a cut never splits an emoji.
    public var menuTitle: String {
        let maxCharacters = 48
        let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard line.count > maxCharacters else { return line }
        var cut = Substring(line.prefix(maxCharacters - 1))
        while cut.last?.isWhitespace == true { cut.removeLast() }
        return cut + "…"
    }

    /// How long ago, for the menu and the History page: "Just now" under a minute, then "1 min ago" … "59 min ago",
    /// "1 hr ago" … "23 hr ago", "1 day ago", "N days ago". A `now` before the entry reads "Just now".
    public func age(now: Int) -> String {
        let minutes = max(0, now - timestampMs) / 60_000
        switch minutes {
        case 0: return "Just now"
        case 1..<60: return "\(minutes) min ago"
        case 60..<1_440: return "\(minutes / 60) hr ago"
        default:
            let days = minutes / 1_440
            return days == 1 ? "1 day ago" : "\(days) days ago"
        }
    }

    /// Whether any searched field (text, application, model) contains `needle`, already lowercased.
    func matches(_ needle: String) -> Bool {
        text.lowercased().contains(needle) || application?.lowercased().contains(needle) == true || model?.lowercased().contains(needle) == true
    }
}

/// A finished dictation awaiting its identity (Hex's `HistoryDraft`).
public struct DictationHistoryDraft: Sendable {
    public var text: String
    public var application: String?
    public var bundleID: String?
    public var model: String?
    public var language: String?

    public init(text: String, application: String? = nil, bundleID: String? = nil, model: String? = nil, language: String? = nil) {
        self.text = text; self.application = application; self.bundleID = bundleID; self.model = model; self.language = language
    }
}
