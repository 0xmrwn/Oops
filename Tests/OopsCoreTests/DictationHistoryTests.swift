import Foundation
@testable import OopsCore
import os
import Testing

/// What Oops's history does differently from Hex's (`src/history.rs` at v3.4.0): no Forever and Off expiring at the
/// month's age, `recent` listing while Off, `replaceText`, the 0o700 folder, `age(now:)`, the sweep's `onSweep`, and
/// `text(of:)` hiding what is past retention. Hex's own tests, ported, are in DictationHistoryHexTests.
struct DictationHistoryTests {
    private let monthMs = DictationHistoryRetention.month.maxAgeMs

    @Test func `retention windows have no forever and off keeps the month`() {
        #expect(DictationHistoryRetention.allCases == [.off, .day, .week, .month])
        #expect(DictationHistoryRetention.day.maxAgeMs == 86_400_000)
        #expect(DictationHistoryRetention.week.maxAgeMs == 7 * 86_400_000)
        #expect(DictationHistoryRetention.month.maxAgeMs == 30 * 86_400_000)
        #expect(DictationHistoryRetention.off.maxAgeMs == DictationHistoryRetention.month.maxAgeMs)
        #expect(DictationHistoryRetention.off.isOff && !DictationHistoryRetention.week.isOff)
    }

    @Test func `off expires entries at thirty days`() throws {
        try DictationHistoryFixture.run { fixture in
            var store = DictationHistoryStore(file: fixture.file, retention: .week, now: 1_000)
            try store.record(draft("kept"), now: 1_000)
            try store.setRetention(.off, now: 1_500)
            let edge = 1_000 + monthMs

            store.expire(now: edge)
            #expect(store.search("kept", now: edge).count == 1)
            // One millisecond later it is hidden at once, and the next expiry removes and saves it.
            #expect(store.search("kept", now: edge + 1).isEmpty)
            #expect(store.entries.count == 1)
            store.expire(now: edge + 1)
            #expect(store.entries.isEmpty)
            #expect(try fixture.savedEntries().isEmpty)
        }
    }

    @Test func `a store opened while off still expires what it kept`() throws {
        try DictationHistoryFixture.run { fixture in
            var store = DictationHistoryStore(file: fixture.file, retention: .week, now: 1_000)
            try store.record(draft("kept"), now: 1_000)

            #expect(DictationHistoryStore(file: fixture.file, retention: .off, now: 1_000 + monthMs).entries.count == 1)
            #expect(DictationHistoryStore(file: fixture.file, retention: .off, now: 1_001 + monthMs).entries.isEmpty)
        }
    }

    @Test func `recent still lists after history is turned off`() throws {
        try DictationHistoryFixture.run { fixture in
            var store = DictationHistoryStore(file: fixture.file, retention: .week, now: 0)
            try store.record(draft("one"), now: 1_000)
            try store.record(draft("  \n"), now: 2_000)
            try store.record(draft("two"), now: 3_000)
            try store.setRetention(.off, now: 4_000)

            #expect(store.recent(5, now: 4_000).map(\.text) == ["two", "one"])
            #expect(store.recent(1, now: 4_000).map(\.text) == ["two"])
            #expect(store.recent(5, now: 1_000 + monthMs + 1).map(\.text) == ["two"], "Off still ages entries out")
            #expect(store.recent(5, now: 3_000 + monthMs + 1).isEmpty)
        }
    }

    @Test func `replaceText replaces truncates and persists`() throws {
        try DictationHistoryFixture.run { fixture in
            var store = DictationHistoryStore(file: fixture.file, retention: .week, now: 0)
            let id = try #require(try store.record(draft("befor"), now: 1_000))
            #expect(try store.replaceText(of: id, with: "before"))
            #expect(try !store.replaceText(of: id + 1, with: "nothing"))
            #expect(DictationHistoryStore(file: fixture.file, retention: .week, now: 2_000).newestFirst.map(\.text) == ["before"])

            let long = String(repeating: "é", count: DictationHistoryStore.maxTextBytes)
            #expect(try store.replaceText(of: id, with: long))
            let kept = try #require(store.newestFirst.first?.text)
            #expect(kept.utf8.count <= DictationHistoryStore.maxTextBytes && long.hasPrefix(kept))
            #expect(store.newestFirst.first?.application == "Zed", "only the text changes")
            #expect(store.newestFirst.first?.timestampMs == 1_000)
        }
    }

    @Test func `a failed replaceText save puts the text back`() throws {
        try DictationHistoryFixture.run { fixture in
            var store = DictationHistoryStore(file: fixture.file, retention: .week, now: 0)
            let id = try #require(try store.record(draft("before"), now: 1_000))
            try FileManager.default.createDirectory(at: fixture.temporary, withIntermediateDirectories: false)

            #expect(throws: (any Error).self) { try store.replaceText(of: id, with: "after") }
            #expect(store.newestFirst.map(\.text) == ["before"])
        }
    }

    @Test func `labels are kept and cut to their cap`() throws {
        try DictationHistoryFixture.run { fixture in
            var store = DictationHistoryStore(file: fixture.file, retention: .week, now: 0)
            let long = String(repeating: "a", count: DictationHistoryStore.maxLabelBytes + 10)
            try store.record(DictationHistoryDraft(text: "hi", application: long, bundleID: long, model: long, language: long), now: 1_000)
            let reopened = DictationHistoryStore(file: fixture.file, retention: .week, now: 1_000)
            let entry = try #require(reopened.newestFirst.first)
            for label in [entry.application, entry.bundleID, entry.model, entry.language] {
                #expect(label?.utf8.count == DictationHistoryStore.maxLabelBytes)
            }
        }
    }

    @Test func `a folder the store creates is owner only`() throws {
        try DictationHistoryFixture.run { fixture in
            let nested = fixture.directory.appendingPathComponent("nested")
            var store = DictationHistoryStore(file: nested.appendingPathComponent("dictations.json"), retention: .week, now: 0)
            try store.record(draft("private"), now: 1_000)

            #expect(try fixture.mode(of: nested) == 0o700)
            #expect(try fixture.mode(of: nested.appendingPathComponent("dictations.json")) == 0o600)
        }
    }

    @Test func `a leftover temporary file is truncated and owner only`() throws {
        try DictationHistoryFixture.run { fixture in
            try Data(repeating: 0x7A, count: 100_000).write(to: fixture.temporary)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fixture.temporary.path)
            var store = DictationHistoryStore(file: fixture.file, retention: .week, now: 0)
            try store.record(draft("fresh"), now: 1_000)

            #expect(try fixture.mode(of: fixture.file) == 0o600)
            #expect(try fixture.savedEntries().map(\.text) == ["fresh"])
        }
    }

    @Test func `an unsupported version is preserved as corrupt`() throws {
        try DictationHistoryFixture.run { fixture in
            let future = Data(#"{"version":2,"nextID":9,"entries":[]}"#.utf8)
            try future.write(to: fixture.file)
            var store = DictationHistoryStore(file: fixture.file, retention: .week, now: 0)

            #expect(store.entries.isEmpty)
            #expect(try Data(contentsOf: URL(fileURLWithPath: fixture.file.path + ".corrupt")) == future)
            #expect(!FileManager.default.fileExists(atPath: fixture.file.path))
            #expect(try store.record(draft("fresh"), now: 1_000) == 1, "a new store counts from one")
        }
    }

    @Test(arguments: [#"{"version":1,"nextID":2,"entries":[{"id":9223372036854775807,"timestampMs":1000,"text":"a"}]}"#,
                      #"{"version":1,"nextID":9223372036854775807,"entries":[]}"#])
    func `an id with no room after it is preserved as corrupt`(saved: String) throws {
        try DictationHistoryFixture.run { fixture in
            try Data(saved.utf8).write(to: fixture.file)
            var store = DictationHistoryStore(file: fixture.file, retention: .week, now: 1_000)

            #expect(store.entries.isEmpty)
            #expect(FileManager.default.fileExists(atPath: fixture.corrupt.path))
            #expect(try store.record(draft("fresh"), now: 1_001) == 1)
        }
    }

    @Test func `clear erases the malformed copy`() throws {
        try DictationHistoryFixture.run { fixture in
            try Data("{ not json".utf8).write(to: fixture.file)
            var store = DictationHistoryStore(file: fixture.file, retention: .week, now: 1_000)
            #expect(FileManager.default.fileExists(atPath: fixture.corrupt.path))

            try store.clear()
            #expect(!FileManager.default.fileExists(atPath: fixture.corrupt.path), "even with no entries to clear")
        }
    }

    @Test func `the sweep drops a malformed copy last written a month ago`() throws {
        try DictationHistoryFixture.run { fixture in
            try Data("{ not json".utf8).write(to: fixture.file)
            let now = DictationHistory.now()
            var store = DictationHistoryStore(file: fixture.file, retention: .day, now: now)
            let written = Date(timeIntervalSince1970: Double(now - monthMs + 60_000) / 1_000)
            try FileManager.default.setAttributes([.modificationDate: written], ofItemAtPath: fixture.corrupt.path)

            store.expire(now: now)
            #expect(FileManager.default.fileExists(atPath: fixture.corrupt.path), "a minute short of a month stays")
            store.expire(now: now + 120_000)
            #expect(!FileManager.default.fileExists(atPath: fixture.corrupt.path))
        }
    }

    @Test func `opening removes a snapshot a crash left behind`() throws {
        try DictationHistoryFixture.run { fixture in
            try Data("half written".utf8).write(to: fixture.temporary)
            _ = DictationHistoryStore(file: fixture.file, retention: .week, now: 1_000)
            #expect(!FileManager.default.fileExists(atPath: fixture.temporary.path))
        }
    }

    @Test func `the next id outlives the saved entries`() throws {
        try DictationHistoryFixture.run { fixture in
            try Data(#"{"version":1,"nextID":2,"entries":[{"id":7,"timestampMs":1000,"text":"b"},{"id":3,"timestampMs":900,"text":"a"}]}"#.utf8)
                .write(to: fixture.file)
            var store = DictationHistoryStore(file: fixture.file, retention: .week, now: 1_000)

            #expect(store.entries.map(\.id) == [3, 7], "sorted by id")
            #expect(try store.record(draft("c"), now: 1_001) == 8)
        }
    }

    @Test func `age reads at each boundary`() {
        let entry = DictationHistoryEntry(id: 1, timestampMs: 1_000_000, text: "x")
        let ages = [
            59_000: "Just now", 60_000: "1 min ago", 59 * 60_000 + 59_000: "59 min ago", 3_600_000: "1 hr ago",
            23 * 3_600_000 + 59 * 60_000: "23 hr ago", 86_400_000: "1 day ago", 2 * 86_400_000: "2 days ago", 0: "Just now"
        ]
        for (elapsed, text) in ages { #expect(entry.age(now: 1_000_000 + elapsed) == text, "\(elapsed) ms") }
        #expect(entry.age(now: 0) == "Just now", "a clock before the entry")
        #expect(entry.date == Date(timeIntervalSince1970: 1_000))
    }

    @Test func `onSweep fires when a sweep expired something and not on an idle tick`() throws {
        try DictationHistoryFixture.run { fixture in
            let dayMs = DictationHistoryRetention.day.maxAgeMs
            var store = DictationHistoryStore(file: fixture.file, retention: .day, now: 0)
            try store.record(draft("old"), now: 1_000)
            let now = OSAllocatedUnfairLock(initialState: 2_000)
            let reads = OSAllocatedUnfairLock(initialState: 0)
            let swept = OSAllocatedUnfairLock(initialState: 0)
            let history = DictationHistory(store: store, interval: 0.01, clock: { reads.withLock { $0 += 1 }; return now.withLock { $0 } }, onSweep: { swept.withLock { $0 += 1 } })

            // Ticks that find nothing to expire stay quiet.
            let quiet = reads.withLock { $0 } + 5
            #expect(waitUntil { reads.withLock { $0 } >= quiet })
            #expect(swept.withLock { $0 } == 0)

            now.withLock { $0 = dayMs + 1_001 }
            #expect(waitUntil { swept.withLock { $0 } >= 1 })
            #expect(history.search("").isEmpty)

            // The tick after that has nothing left to expire either.
            let before = swept.withLock { $0 }
            let later = reads.withLock { $0 } + 5
            #expect(waitUntil { reads.withLock { $0 } >= later })
            #expect(swept.withLock { $0 } == before)
        }
    }

    @Test func `text is nil once the entry is past retention or deleted`() throws {
        try DictationHistoryFixture.run { fixture in
            let dayMs = DictationHistoryRetention.day.maxAgeMs
            let now = OSAllocatedUnfairLock(initialState: 1_000)
            let store = DictationHistoryStore(file: fixture.file, retention: .day, now: 0)
            // A long interval keeps the sweep out of it: the read itself must hide the entry.
            let history = DictationHistory(store: store, interval: 3_600, clock: { now.withLock { $0 } })
            let id = try #require(try history.record(draft("hello")))
            let other = try #require(try history.record(draft("other")))
            #expect(history.text(of: id) == "hello")
            #expect(try history.delete(other))
            #expect(history.text(of: other) == nil)

            now.withLock { $0 = 1_000 + dayMs }
            #expect(history.text(of: id) == "hello")
            now.withLock { $0 = 1_000 + dayMs + 1 }
            #expect(history.text(of: id) == nil)
            #expect(history.text(of: 999) == nil)
        }
    }

    @Test func `the handle records searches and clears under its lock`() throws {
        try DictationHistoryFixture.run { fixture in
            let store = DictationHistoryStore(file: fixture.file, retention: .off, now: 0)
            let history = DictationHistory(store: store, interval: 3_600, clock: { 5_000 })
            #expect(try history.record(draft("while off")) == nil)
            try history.setRetention(.week)
            #expect(history.retention == .week)
            let revision = history.revision()
            let id = try #require(try history.record(draft("Hello")))
            #expect(history.revision() != revision)
            #expect(history.search("hello").map(\.id) == [id])
            #expect(history.recent(3).map(\.text) == ["Hello"])
            #expect(try history.replaceText(of: id, with: "Bye"))
            try history.clear()
            #expect(history.search("").isEmpty)
        }
    }
}

// MARK: Shared by the history tests

/// A fresh store file in its own temporary folder, removed when `run` returns.
struct DictationHistoryFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("oops-dictation-history-\(UUID().uuidString)")
    var file: URL { directory.appendingPathComponent("history.json") }
    var temporary: URL { directory.appendingPathComponent("history.json.tmp") }
    var corrupt: URL { directory.appendingPathComponent("history.json.corrupt") }

    static func run(_ body: (DictationHistoryFixture) throws -> Void) throws {
        let fixture = DictationHistoryFixture()
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try body(fixture)
    }

    func setModified(_ date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
    }

    func modified() throws -> Date? {
        try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
    }

    func mode(of url: URL) throws -> Int {
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        return (permissions ?? 0) & 0o777
    }

    func savedEntries() throws -> [DictationHistoryEntry] {
        try JSONDecoder().decode(DictationHistoryStore.Saved.self, from: Data(contentsOf: file)).entries
    }
}

/// A draft from Zed, made by a model called "Messages" (Hex's draft names a processing profile with that name).
func draft(_ text: String) -> DictationHistoryDraft {
    DictationHistoryDraft(text: text, application: "Zed", bundleID: "dev.zed.Zed", model: "Messages", language: "en")
}

/// Polls `condition` every few milliseconds until it holds or the timeout passes.
func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline { return false }
        Thread.sleep(forTimeInterval: 0.005)
    }
    return true
}

extension DictationHistoryEntry {
    func with(id: Int) -> DictationHistoryEntry {
        DictationHistoryEntry(id: id, timestampMs: timestampMs, text: text, application: application, bundleID: bundleID, model: model, language: language)
    }
}
