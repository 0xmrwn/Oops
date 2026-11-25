import Foundation
import os

// The dictation history store, ported from Hex (github.com/anomalyco/hex, `src/history.rs` at v3.4.0; MIT, Copyright
// (c) 2026 Christopher Langton). See THIRD_PARTY_NOTICES.md. Left out: recordings and their byte cap (Oops never keeps
// audio), versions and restore, kind, processing and timing fields (but the recording's length), `read_snapshot`, and
// `sync`/`file_state` (Hex rereads because Linux runs two processes on one store; Oops is one process), so
// `expire_shared` is just `expire`.
// Departures: no Forever, and Off expires at the month's age, so `prune`, `search`, `recent` and `revision` always
// have a cutoff; `recent` still lists while Off, the caller decides what Off means for Paste last; the folder is 0o700.
// Dictated words persist only here: nothing in this store logs entry text or a query.

/// Owner-only bounded store; entries held oldest first (Hex's `HistoryStore`). A value type with mutating methods, as
/// the Rust takes `&mut self`.
public struct DictationHistoryStore: Sendable {
    public static let maxSearchResults = 200
    static let version = 1
    static let maxEntries = 10_000
    static let maxTextBytes = 16 * 1024
    static let maxLabelBytes = 256
    static let maxTotalTextBytes = 16 * 1024 * 1024
    static let log = Logger(subsystem: "dev.0xmrwn.oops", category: "DictationHistory")

    let file: URL
    var entries: [DictationHistoryEntry] = []
    var nextID = 1
    public internal(set) var retention: DictationHistoryRetention
    var prunePending = false
    var pruneErrorReported = false
    /// Changes whenever what a search could return may have changed: a record, delete, edit, clear, prune or
    /// retention change. The History page searches again only then.
    var revisionCounter = 0

    /// Hex's `open`: load, recover from unreadable content (a malformed file is preserved beside the store, never
    /// silently destroyed), and expire.
    public init(file: URL, retention: DictationHistoryRetention, now: Int) {
        self.file = file
        self.retention = retention
        load()
        expire(now: now)
    }

    mutating func touch() { revisionCounter &+= 1 }

    /// The oldest timestamp still kept at `now`: an entry exactly at the cutoff stays (Hex's saturating_sub).
    func cutoff(now: Int) -> Int { max(0, now - retention.maxAgeMs) }

    /// The store's revision, which moves whenever a search could answer differently. An oldest entry past retention
    /// is pruned in memory first, so the revision also moves when time expires one; the sweep saves that prune.
    public mutating func revision(now: Int) -> Int {
        if let oldest = entries.first, oldest.timestampMs < cutoff(now: now) { prune(now: now) }
        return revisionCounter
    }

    /// Records one dictation. Returns its stable entry ID, or nil while retention is off.
    @discardableResult public mutating func record(_ draft: DictationHistoryDraft, now: Int) throws -> Int? {
        if retention.isOff { return nil }
        let id = nextID
        nextID += 1
        let label = { (value: String?) in value.map { Self.truncated($0, maxBytes: Self.maxLabelBytes) } }
        entries.append(DictationHistoryEntry(
            id: id, timestampMs: now, text: Self.truncated(draft.text, maxBytes: Self.maxTextBytes),
            application: label(draft.application), bundleID: label(draft.bundleID), model: label(draft.model), language: label(draft.language),
            durationMs: draft.durationMs
        ))
        prune(now: now)
        try persist()
        return id
    }

    /// Deletes one entry; returns whether it existed. A failed save keeps the entry, so the deletion can be retried.
    @discardableResult public mutating func delete(_ id: Int) throws -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return false }
        let removed = entries.remove(at: index)
        do { try persist() } catch {
            entries.insert(removed, at: index)
            throw error
        }
        return true
    }

    /// Port of Hex's `change` (used by its `replace_text`) without versions: the text is replaced (truncated to
    /// `maxTextBytes`), and a failed save puts it back.
    @discardableResult public mutating func replaceText(of id: Int, with text: String) throws -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return false }
        let previous = entries[index]
        entries[index].text = Self.truncated(text, maxBytes: Self.maxTextBytes)
        do { try persist() } catch {
            entries[index] = previous
            throw error
        }
        return true
    }

    /// Deletes every entry, and the copy of a malformed file. A failed save keeps them, so the clear can be retried.
    public mutating func clear() throws {
        try removeCorrupt()
        if entries.isEmpty, !prunePending { return }
        let removed = entries
        entries = []
        do { try persist() } catch {
            entries = removed
            throw error
        }
    }

    /// Changes retention and immediately prunes to the new window. Turning history off stops recording but keeps
    /// existing entries until they are deleted or age out.
    public mutating func setRetention(_ retention: DictationHistoryRetention, now: Int) throws {
        if self.retention == retention { return }
        self.retention = retention
        touch()
        if prune(now: now) { try persist() }
    }

    /// All entries, newest first (Hex's `entries()`).
    public var newestFirst: [DictationHistoryEntry] { entries.reversed() }

    /// Case-insensitive substring search over text, application and model. Newest first and bounded; entries past
    /// retention are hidden without being removed or written.
    public func search(_ query: String, now: Int) -> [DictationHistoryEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let cutoff = cutoff(now: now)
        let matches = entries.reversed().lazy.filter { $0.timestampMs >= cutoff && (needle.isEmpty || $0.matches(needle)) }
        return Array(matches.prefix(Self.maxSearchResults))
    }

    /// The newest `count` entries within retention that a paste could reuse: none with blank text. DEPARTURE from
    /// Hex: it does not return nothing while Off, so the menu keeps listing what is still kept.
    public func recent(_ count: Int, now: Int) -> [DictationHistoryEntry] {
        let cutoff = cutoff(now: now)
        let usable = entries.reversed().lazy.filter { $0.timestampMs >= cutoff && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return Array(usable.prefix(count))
    }

    /// The sweep's expiry: drop a month-old malformed copy, prune, and save if that left a change unsaved. A failed
    /// save is reported once and retried on the next call.
    public mutating func expire(now: Int) {
        do { try removeCorrupt(modifiedBefore: now - DictationHistoryRetention.month.maxAgeMs) } catch {
            Self.log.warning("could not remove the malformed dictation history's copy (\(Self.describe(error), privacy: .public))")
        }
        prune(now: now)
        guard prunePending else { return }
        do { try persist() } catch {
            if !pruneErrorReported { Self.log.warning("could not save the pruned history; will retry (\(Self.describe(error), privacy: .public))") }
            pruneErrorReported = true
        }
    }

    /// Drops what is past retention, then the oldest past the entry cap, then the oldest past the text cap (one entry
    /// always stays). Returns whether anything went.
    @discardableResult mutating func prune(now: Int) -> Bool {
        let cutoff = cutoff(now: now)
        let before = entries.count
        entries.removeAll { $0.timestampMs < cutoff }
        var changed = entries.count != before
        if entries.count > Self.maxEntries {
            entries.removeFirst(entries.count - Self.maxEntries)
            changed = true
        }
        var total = entries.reduce(0) { $0 + $1.textBytes }
        var remove = 0
        while total > Self.maxTotalTextBytes && remove + 1 < entries.count {
            total -= entries[remove].textBytes
            remove += 1
        }
        entries.removeFirst(remove)
        changed = changed || remove > 0
        prunePending = prunePending || changed
        if changed { touch() }
        return changed
    }
}
