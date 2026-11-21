import Foundation
@testable import OopsCore
import os
import Testing

/// The rest of Hex's tests of the history store (`src/history.rs` at v3.4.0), under their upstream names: search,
/// recent, and the idle sweep. See DictationHistoryHexTests for what was left out and why.
struct DictationHistoryHexSweepTests {
    @Test func `search hides expired entries before the next idle prune`() throws {
        try DictationHistoryFixture.run { fixture in
            let dayMs = DictationHistoryRetention.day.maxAgeMs
            var store = DictationHistoryStore(file: fixture.file, retention: .day, now: 0)
            try store.record(draft("old"), now: 1_000)
            try store.record(draft("fresh"), now: 2_000)
            try fixture.setModified(Date(timeIntervalSince1970: 0))

            #expect(store.search("", now: dayMs + 1_000).count == 2)
            #expect(store.search("old", now: dayMs + 1_001).isEmpty)
            let matches = store.search("", now: dayMs + 1_001)
            #expect(matches.map(\.text) == ["fresh"])
            #expect(store.entries.count == 2, "reads filter without writing on the UI thread")
            #expect(try fixture.modified() == Date(timeIntervalSince1970: 0))
        }
    }

    @Test func `idle worker expires entries on disk without recording or reading`() throws {
        try DictationHistoryFixture.run { fixture in
            let dayMs = DictationHistoryRetention.day.maxAgeMs
            var store = DictationHistoryStore(file: fixture.file, retention: .day, now: 0)
            try store.record(draft("old"), now: 1_000)
            try store.record(draft("fresh"), now: 2_000)
            let now = OSAllocatedUnfairLock(initialState: 2_000)
            let sampled = OSAllocatedUnfairLock(initialState: Set<Int>())
            let history = DictationHistory(store: store, interval: 0.01, clock: {
                let value = now.withLock { $0 }
                sampled.withLock { _ = $0.insert(value) }
                return value
            })
            func tick(_ value: Int) {
                now.withLock { $0 = value }
                #expect(waitUntil { sampled.withLock { $0.contains(value) } }, "the sweep never read the clock")
                // The clock is sampled under the lock; taking it waits for that prune.
                history.locked { _ in }
            }
            try fixture.setModified(Date(timeIntervalSince1970: 0))

            tick(dayMs + 1_000)
            #expect(try fixture.modified() == Date(timeIntervalSince1970: 0))

            tick(dayMs + 1_001)
            #expect(try fixture.savedEntries().map(\.text) == ["fresh"])

            tick(dayMs + 2_001)
            #expect(try fixture.savedEntries().isEmpty)
            try fixture.setModified(Date(timeIntervalSince1970: 0))
            tick(2 * dayMs)
            #expect(try fixture.modified() == Date(timeIntervalSince1970: 0))
            withExtendedLifetime(history) {}
        }
    }

    @Test func `failed expiry persistence retries without new removals`() throws {
        try DictationHistoryFixture.run { fixture in
            let dayMs = DictationHistoryRetention.day.maxAgeMs
            var store = DictationHistoryStore(file: fixture.file, retention: .day, now: 0)
            try store.record(draft("old"), now: 1_000)
            let temporary = fixture.temporary
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)

            store.expire(now: dayMs + 1_001)
            #expect(store.entries.isEmpty)
            #expect(store.prunePending)
            #expect(store.pruneErrorReported)
            #expect(try fixture.savedEntries().count == 1)
            store.expire(now: dayMs + 1_002)
            #expect(store.prunePending)
            #expect(store.pruneErrorReported)

            try FileManager.default.removeItem(at: temporary)
            store.expire(now: dayMs + 1_003)
            #expect(!store.prunePending)
            #expect(!store.pruneErrorReported)
            #expect(try fixture.savedEntries().isEmpty)
        }
    }

    /// The Rust drops a clone and watches its worker's channel disconnect; here the clock closure holds a sentinel,
    /// and the handle's timer must not keep the handle, or the closure, alive.
    @Test func `idle worker stops when the last history handle is dropped`() throws {
        try DictationHistoryFixture.run { fixture in
            final class Sentinel: Sendable {}
            let store = DictationHistoryStore(file: fixture.file, retention: .day, now: 0)
            var history: DictationHistory?
            weak var alive: Sentinel?
            do {
                let sentinel = Sentinel()
                alive = sentinel
                history = DictationHistory(store: store, interval: 0.01, clock: { _ = sentinel; return 0 })
            }
            var clone = history
            history = nil
            // Let the timer fire a few times against the live handle: it must neither crash nor release it.
            Thread.sleep(forTimeInterval: 0.05)
            #expect(alive != nil)

            clone = nil
            #expect(waitUntil { alive == nil }, "the timer must not keep the handle alive")
            _ = clone
        }
    }

    @Test func `search is case insensitive across text application and profile`() throws {
        try DictationHistoryFixture.run { fixture in
            var store = DictationHistoryStore(file: fixture.file, retention: .week, now: 0)
            try store.record(draft("Hello World"), now: 1_000)
            try store.record(draft("other text"), now: 2_000)

            #expect(store.search("hello world", now: 2_000).count == 1)
            #expect(store.search("zed", now: 2_000).count == 2)
            // Rust: the processing profile "Messages"; Oops searches the model name instead.
            #expect(store.search("messages", now: 2_000).count == 2)
            #expect(store.search("absent", now: 2_000).isEmpty)
            #expect(store.search("  ", now: 2_000).count == 2, "blank queries list everything")
        }
    }

    /// Adapted: there are no Printed entries, so none is recorded, and after Off the entries are still listed.
    @Test func `recent lists the newest reusable entries within retention`() throws {
        try DictationHistoryFixture.run { fixture in
            let dayMs = DictationHistoryRetention.day.maxAgeMs
            var store = DictationHistoryStore(file: fixture.file, retention: .day, now: 0)
            try store.record(draft("expired"), now: 1_000)
            for (index, text) in ["one", "two", "  ", "three"].enumerated() { try store.record(draft(text), now: dayMs + index) }
            try store.record(draft("four"), now: dayMs + 20)

            func texts(_ count: Int) -> [String] { store.recent(count, now: dayMs + 1_001).map(\.text) }
            #expect(texts(5) == ["four", "three", "two", "one"])
            #expect(texts(2) == ["four", "three"])
            try store.setRetention(.off, now: dayMs + 1_001)
            // The window is now the month's, so the entry that was past the day's is back (Rust: "Off lists nothing").
            #expect(texts(5) == ["four", "three", "two", "one", "expired"], "Off still lists what is kept")
        }
    }
}
