import Foundation

// The dictation history's retention, ported from Hex (github.com/anomalyco/hex, `src/history.rs` at v3.4.0; MIT,
// Copyright (c) 2026 Christopher Langton). See THIRD_PARTY_NOTICES.md. Left out: Forever, since Oops never keeps
// dictated words past 30 days; and Hex's `label`, which Settings words itself.

/// How long finished dictations stay in history.
public enum DictationHistoryRetention: String, CaseIterable, Sendable, Codable {
    case off, day, week, month

    public var isOff: Bool { self == .off }

    /// The age, in milliseconds, past which an entry is gone. DEPARTURE from Hex: Off has one too, the month's,
    /// so entries kept from before history was turned off still expire (Hex keeps them until deleted).
    public var maxAgeMs: Int {
        let hour = 60 * 60 * 1_000
        switch self {
        case .day: return 24 * hour
        case .week: return 7 * 24 * hour
        case .month, .off: return 30 * 24 * hour
        }
    }
}
