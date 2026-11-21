import Foundation
@testable import OopsCore
import os
import Testing

/// Hex's tests of the history store (`src/history.rs` at v3.4.0) and of `recent_title` (`src/macos_rune/status_item.rs`),
/// under their upstream names, adapted where Oops's departures force it (each says which line of the Rust). Not
/// ported, because what they test is not in Oops:
/// - the recordings tests (`a_kept_recording_is_an_owner_only_wav_that_reads_back`, `recordings_leave_with_their_entries`,
///   `the_recordings_byte_cap_drops_the_oldest_audio_but_keeps_the_text`, `a_recording_another_process_has_not_saved_yet_survives_a_sweep`,
///   `retranscribing_a_missing_recording_says_so`): Oops never keeps audio;
/// - `replacing_the_text_keeps_the_entry_and_its_recording`: versions and audio (`replaceText` has its own tests in
///   DictationHistoryTests);
/// - `stores_in_two_processes_see_each_others_writes` and `expiry_in_a_stale_process_keeps_the_other_processes_writes`:
///   Oops is one process, so there is no `sync`;
/// - `field_matching_agrees_with_full_lowercasing`: Oops searches with plain `lowercased().contains`, so there is no
///   ASCII fast path to agree with;
/// - `search_still_finds_raw_text_that_differs_from_the_final_text`: Oops keeps no raw text.
/// The search, retention and idle-sweep tests are in DictationHistoryHexSweepTests.
struct DictationHistoryHexTests {
    @Test func `records survive reopen with monotonic ids`() throws {
        try DictationHistoryFixture.run { fixture in
            var store = DictationHistoryStore(file: fixture.file, retention: .week, now: 1_000)
            let first = try #require(try store.record(draft("first"), now: 1_000))
            let second = try #require(try store.record(draft("second"), now: 2_000))
            #expect(second > first)
            try store.delete(second)

            var reopened = DictationHistoryStore(file: fixture.file, retention: .week, now: 2_500)
            #expect(reopened.entries.count == 1)
            let third = try #require(try reopened.record(draft("third"), now: 3_000))
            #expect(third > second, "deleted IDs are never reused")
            #expect(reopened.newestFirst.map(\.text) == ["third", "first"])
        }
    }

    @Test func `retention prunes expired entries on open and write`() throws {
        try DictationHistoryFixture.run { fixture in
            let dayMs = 24 * 60 * 60 * 1_000
            var store = DictationHistoryStore(file: fixture.file, retention: .day, now: 0)
            try store.record(draft("old"), now: 1_000)
            try store.record(draft("fresh"), now: dayMs)

            // A write one day later prunes the first entry exactly at the cutoff.
            try store.record(draft("newest"), now: dayMs + 1_001)
            #expect(store.newestFirst.map(\.text) == ["newest", "fresh"])

            let reopened = DictationHistoryStore(file: fixture.file, retention: .day, now: 2 * dayMs + 500)
            #expect(reopened.newestFirst.map(\.text) == ["newest"])
        }
    }

    @Test func `choosing week retention from month keeps entries newer than a week`() throws {
        try DictationHistoryFixture.run { fixture in
            let dayMs = 24 * 60 * 60 * 1_000
            let now = 30 * dayMs
            var store = DictationHistoryStore(file: fixture.file, retention: .month, now: 0)
            try store.record(draft("twenty days old"), now: now - 20 * dayMs)
            try store.record(draft("two days old"), now: now - 2 * dayMs)

            try store.setRetention(.week, now: now)

            #expect(store.newestFirst.map(\.text) == ["two days old"])
        }
    }

    /// Adapted from the Rust's `off_records_nothing_but_preserves_existing_entries`: Off has the month's age here
    /// (Rust: `later = month + 2_000` and the entry survives), so the entry survives up to exactly `1_000 + month`.
    @Test func `off records nothing but preserves existing entries`() throws {
        try DictationHistoryFixture.run { fixture in
            var store = DictationHistoryStore(file: fixture.file, retention: .week, now: 1_000)
            try store.record(draft("kept"), now: 1_000)
            try store.setRetention(.off, now: 1_500)
            try fixture.setModified(Date(timeIntervalSince1970: 0))

            #expect(try store.record(draft("dropped"), now: 2_000) == nil)
            let later = 1_000 + DictationHistoryRetention.month.maxAgeMs
            store.expire(now: later)
            #expect(store.entries.count == 1)
            #expect(store.search("kept", now: later).count == 1)
            #expect(try fixture.modified() == Date(timeIntervalSince1970: 0))
        }
    }

    @Test func `hard caps bound entries and text regardless of retention`() throws {
        try DictationHistoryFixture.run { fixture in
            // Rust: Forever. There is none here, so the widest window is the month.
            var store = DictationHistoryStore(file: fixture.file, retention: .month, now: 0)
            try store.record(draft("entry"), now: 0)
            let template = store.entries[0]
            store.entries = (0..<DictationHistoryStore.maxEntries + 5).map { template.with(id: $0) }
            store.prune(now: 0)
            #expect(store.entries.count == DictationHistoryStore.maxEntries)
            #expect(store.entries[0].id == 5, "the oldest entries are evicted")
            store.nextID = DictationHistoryStore.maxEntries + 5

            let oversized = String(repeating: "x", count: DictationHistoryStore.maxTextBytes + 100)
            let id = try #require(try store.record(draft(oversized), now: 9_999_999))
            #expect(store.entries.first { $0.id == id }?.text.utf8.count == DictationHistoryStore.maxTextBytes)
        }
    }

    @Test func `total text bytes evict oldest entries`() throws {
        try DictationHistoryFixture.run { fixture in
            var store = DictationHistoryStore(file: fixture.file, retention: .month, now: 0)
            let big = String(repeating: "y", count: DictationHistoryStore.maxTextBytes - 10)
            // One text per entry (Rust: raw and final), so an entry weighs its text's bytes. The copies share one buffer.
            let perEntry = big.utf8.count
            let fits = DictationHistoryStore.maxTotalTextBytes / perEntry
            try store.record(draft(big), now: 0)
            let template = store.entries[0]
            store.entries = (0..<fits + 3).map { template.with(id: $0) }
            store.prune(now: 0)
            let total = store.entries.reduce(0) { $0 + $1.text.utf8.count }
            #expect(total <= DictationHistoryStore.maxTotalTextBytes)
            #expect(store.entries.count < fits + 3)
            #expect(store.entries[0].id > 0, "byte pressure also evicts oldest first")
        }
    }

    @Test func `clear removes everything durably`() throws {
        try DictationHistoryFixture.run { fixture in
            var store = DictationHistoryStore(file: fixture.file, retention: .week, now: 0)
            try store.record(draft("one"), now: 1_000)
            try store.record(draft("two"), now: 2_000)
            try store.clear()

            #expect(store.entries.isEmpty)
            #expect(DictationHistoryStore(file: fixture.file, retention: .week, now: 3_000).entries.isEmpty)
        }
    }

    @Test func `failed clear and delete keep entries for a retry`() throws {
        try DictationHistoryFixture.run { fixture in
            var store = DictationHistoryStore(file: fixture.file, retention: .week, now: 0)
            let first = try #require(try store.record(draft("one"), now: 1_000))
            try store.record(draft("two"), now: 2_000)
            let temporary = fixture.temporary
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)

            #expect(throws: (any Error).self) { try store.delete(first) }
            #expect(throws: (any Error).self) { try store.clear() }
            #expect(store.entries.count == 2, "a failed save keeps the entries")

            try FileManager.default.removeItem(at: temporary)
            #expect(try store.delete(first))
            try store.clear()
            #expect(DictationHistoryStore(file: fixture.file, retention: .week, now: 3_000).entries.isEmpty)
        }
    }

    @Test func `malformed files are preserved and recovered from`() throws {
        try DictationHistoryFixture.run { fixture in
            try Data("{ not json".utf8).write(to: fixture.file)
            var store = DictationHistoryStore(file: fixture.file, retention: .week, now: 0)
            #expect(store.entries.isEmpty)
            #expect(FileManager.default.fileExists(atPath: fixture.file.path + ".corrupt"))

            try store.record(draft("fresh"), now: 1_000)
            #expect(DictationHistoryStore(file: fixture.file, retention: .week, now: 2_000).entries.count == 1)
        }
    }

    /// Adds, to the Rust, that the temporary file is gone once the save is done.
    @Test func `history files are owner only`() throws {
        try DictationHistoryFixture.run { fixture in
            var store = DictationHistoryStore(file: fixture.file, retention: .week, now: 0)
            try store.record(draft("private"), now: 1_000)

            #expect(try fixture.mode(of: fixture.file) == 0o600)
            #expect(!FileManager.default.fileExists(atPath: fixture.temporary.path))
        }
    }

    @Test func `truncation respects character boundaries`() {
        let text = String(repeating: "é", count: DictationHistoryStore.maxTextBytes)
        let truncated = DictationHistoryStore.truncated(text, maxBytes: DictationHistoryStore.maxTextBytes)
        #expect(truncated.utf8.count <= DictationHistoryStore.maxTextBytes)
        #expect(text.hasPrefix(truncated))
    }

    @Test func `the revision moves only when a search could change`() throws {
        try DictationHistoryFixture.run { fixture in
            let dayMs = DictationHistoryRetention.day.maxAgeMs
            var store = DictationHistoryStore(file: fixture.file, retention: .day, now: 0)
            var last = store.revision(now: 0)
            func moved(_ store: inout DictationHistoryStore, _ now: Int) -> Bool {
                let revision = store.revision(now: now)
                defer { last = revision }
                return revision != last
            }
            #expect(!moved(&store, 0), "nothing changed")

            let old = try #require(try store.record(draft("old"), now: 1_000))
            #expect(moved(&store, 1_000), "a record")
            try store.record(draft("fresh"), now: 2_000)
            #expect(moved(&store, 2_000))
            #expect(!moved(&store, dayMs + 1_000))

            #expect(moved(&store, dayMs + 1_001), "time expired the oldest")
            #expect(!store.entries.contains { $0.id == old })

            // Rust: Forever, and a step where another process writes, which has no counterpart here.
            try store.setRetention(.week, now: dayMs + 1_002)
            #expect(moved(&store, dayMs + 1_002), "retention")
            let id = try #require(store.newestFirst.first?.id)
            try store.delete(id)
            #expect(moved(&store, dayMs + 1_002), "a delete")
            #expect(!moved(&store, dayMs + 1_002))
        }
    }

    @Test func `recent dictations show on one short line`() {
        func title(_ text: String) -> String { DictationHistoryEntry(id: 1, timestampMs: 0, text: text).menuTitle }
        #expect(title("  Hello\nthere,\n\n  world  ") == "Hello there, world")
        let long = title("A long dictation that goes on\nand on well past what fits on one menu line")
        #expect(long == "A long dictation that goes on and on well past…")
        #expect(long.count == 47)
    }
}
