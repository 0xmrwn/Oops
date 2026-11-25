import Foundation
@testable import OopsCore
import Testing

/// The recent dictations' second line (age, recording length, words), the word count it shares with Stats, and the
/// recording length kept across versions of the history file.
struct DictationHistoryDetailsTests {
    private let minute = 60_000

    @Test func `word counts use whitespace and newline character boundaries`() {
        #expect(Words.count(in: "") == 0)
        #expect(Words.count(in: " \t\r\n\u{00A0}\u{2028}\u{2029}") == 0)
        #expect(Words.count(in: "  one-two\tcan't\r\nthree  ") == 3)
        #expect(Words.count(in: "cafe\u{0301}\u{00A0}👩🏽‍💻\u{2028}مرحبا") == 3)
        #expect(Words.count(in: "two\u{200B}words") == 1)
    }

    @Test func `durations read as a clock to the nearest second`() {
        let durations = [0: "0:00", 499: "0:00", 500: "0:01", 7_000: "0:07", 59_499: "0:59", 59_500: "1:00", 83_000: "1:23",
                         725_000: "12:05", 3_599_000: "59:59", 3_600_000: "1:00:00", 3_725_000: "1:02:05", 36_000_000: "10:00:00", -5: "0:00"]
        for (ms, text) in durations { #expect(DictationHistoryEntry.duration(ms: ms) == text, "\(ms) ms") }
        // A value a file could hold: it rounds without overflowing, and the spoken length uses the same seconds.
        #expect(DictationHistoryEntry.seconds(ms: .max) == Int.max / 1_000 + 1)
        #expect(!DictationHistoryEntry.duration(ms: .max).isEmpty)
        #expect(DictationHistoryEntry.seconds(ms: 2_500) == 3)
    }

    @Test func `the second line has the age, the length when kept and the words`() {
        let now = 10 * minute
        func entry(_ text: String, durationMs: Int? = nil) -> DictationHistoryEntry {
            DictationHistoryEntry(id: 1, timestampMs: now - 5 * minute, text: text, durationMs: durationMs)
        }
        #expect(entry("Let’s move the review to Thursday", durationMs: 6_600).details(now: now) == "5 min ago · 0:07 · 6 words")
        #expect(entry("Let’s move the review to Thursday").details(now: now) == "5 min ago · 6 words", "kept before lengths were")
        #expect(entry("Thanks.", durationMs: 1_200).details(now: now) == "5 min ago · 0:01 · 1 word")
        #expect(entry(" \n", durationMs: 0).details(now: now) == "5 min ago · 0:00 · 0 words")
        #expect(entry("On se retrouve jeudi", durationMs: 3_725_000).details(now: now) == "5 min ago · 1:02:05 · 4 words")
    }

    @Test func `a recorded length is saved and read back`() throws {
        try DictationHistoryFixture.run { fixture in
            var store = DictationHistoryStore(file: fixture.file, retention: .week, now: 1_000)
            try store.record(DictationHistoryDraft(text: "with", durationMs: 7_000), now: 1_000)
            try store.record(DictationHistoryDraft(text: "without"), now: 2_000)
            #expect(try fixture.savedEntries().map(\.durationMs) == [7_000, nil])
            let reopened = DictationHistoryStore(file: fixture.file, retention: .week, now: 3_000)
            #expect(reopened.newestFirst.map(\.durationMs) == [nil, 7_000])
        }
    }

    @Test func `a history from before lengths were kept loads with every entry`() throws {
        try DictationHistoryFixture.run { fixture in
            let old = #"""
            {"version":1,"nextID":4,"entries":[
            {"id":1,"timestampMs":1000,"text":"Thanks for the notes.","application":"Mail","bundleID":"com.apple.mail","model":"Parakeet","language":"en"},
            {"id":2,"timestampMs":2000,"text":"On se retrouve jeudi.","application":"Notes","bundleID":"com.apple.Notes","model":"Whisper","language":"fr"},
            {"id":3,"timestampMs":3000,"text":"No app known."}]}
            """#
            try Data(old.utf8).write(to: fixture.file)
            let store = DictationHistoryStore(file: fixture.file, retention: .week, now: 4_000)
            #expect(store.newestFirst == [
                DictationHistoryEntry(id: 3, timestampMs: 3_000, text: "No app known."),
                DictationHistoryEntry(id: 2, timestampMs: 2_000, text: "On se retrouve jeudi.", application: "Notes", bundleID: "com.apple.Notes",
                                      model: "Whisper", language: "fr"),
                DictationHistoryEntry(id: 1, timestampMs: 1_000, text: "Thanks for the notes.", application: "Mail", bundleID: "com.apple.mail",
                                      model: "Parakeet", language: "en"),
            ])
            #expect(store.nextID == 4)
            #expect(!FileManager.default.fileExists(atPath: fixture.corrupt.path), "not set aside as malformed")
        }
    }

    /// The previous version's file shape (version 1, entries without the length) reads a file this version wrote: the
    /// version is unchanged and synthesized decoding ignores the extra key.
    @Test func `a history with lengths still reads as the previous version's shape`() throws {
        struct PreviousEntry: Decodable, Equatable { let id: Int, timestampMs: Int, text: String, application: String?, bundleID: String? }
        struct PreviousSaved: Decodable { let version: Int, nextID: Int, entries: [PreviousEntry] }
        try DictationHistoryFixture.run { fixture in
            var store = DictationHistoryStore(file: fixture.file, retention: .week, now: 1_000)
            try store.record(DictationHistoryDraft(text: "kept", application: "Notes", bundleID: "com.apple.Notes", durationMs: 7_000), now: 1_000)
            let saved = try JSONDecoder().decode(PreviousSaved.self, from: Data(contentsOf: fixture.file))
            #expect(saved.version == 1)
            #expect(saved.entries == [PreviousEntry(id: 1, timestampMs: 1_000, text: "kept", application: "Notes", bundleID: "com.apple.Notes")])
        }
    }
}
