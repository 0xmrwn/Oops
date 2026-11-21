@testable import Oops
import OopsCore
import XCTest

/// The app's history over a temporary file and a throwaway defaults suite: retention, what Paste last reads, and
/// what the menu lists.
@MainActor final class DictationHistoryModelTests: XCTestCase {
    private var file: URL!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "dictation-history-\(UUID().uuidString)")
        file = folder.appending(path: "dictations.json")
        let suite = "DictationHistoryModelTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { [defaults] in
            defaults?.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }
    }

    private func model() -> DictationHistoryModel { DictationHistoryModel(file: file, defaults: defaults) }

    private func record(_ model: DictationHistoryModel, _ text: String) {
        model.record(text: text, language: "en", model: "Whisper", application: "Notes", bundleID: "com.apple.Notes")
    }

    func testRetentionIsAWeekUntilChosenAndIsSaved() {
        let first = model()
        XCTAssertEqual(first.retention, .week)
        first.retention = .day
        XCTAssertEqual(defaults.string(forKey: DictationHistoryRetention.key), "day")
        XCTAssertEqual(model().retention, .day)
    }

    func testOffPastesFromMemoryAndRecordsNothing() {
        let history = model()
        history.retention = .off
        record(history, "Hello")
        XCTAssertEqual(history.recent(), [])
        XCTAssertEqual(history.lastText(inMemory: "Hello"), "Hello")
        XCTAssertNil(history.lastText(inMemory: nil))
    }

    func testOnPastesTheNewestEntryAfterARelaunchAndNothingOnceCleared() throws {
        let history = model()
        let before = history.revision
        record(history, "First")
        record(history, "Second")
        XCTAssertNotEqual(history.revision, before)
        XCTAssertEqual(history.lastText(inMemory: "In memory"), "Second")
        let relaunched = model()
        XCTAssertEqual(relaunched.lastText(inMemory: nil), "Second")
        let entry = try XCTUnwrap(relaunched.recent().first)
        XCTAssertEqual(entry.application, "Notes")
        XCTAssertEqual(entry.bundleID, "com.apple.Notes")
        XCTAssertEqual(entry.model, "Whisper")
        XCTAssertEqual(entry.language, "en")
        try relaunched.clear()
        XCTAssertNil(relaunched.lastText(inMemory: "In memory"), "a cleared dictation isn't pasted from memory")
    }

    func testADictationThatCouldNotBeSavedIsPastedFromMemory() throws {
        let history = model()
        record(history, "Saved")
        // A folder where the store's temporary file goes makes the next save fail.
        let blocker = URL(fileURLWithPath: file.path + ".tmp")
        try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: false)
        record(history, "Unsaved")
        XCTAssertEqual(history.lastText(inMemory: "Unsaved"), "Unsaved")
        try FileManager.default.removeItem(at: blocker)
        record(history, "Saved again")
        XCTAssertEqual(history.lastText(inMemory: "In memory"), "Saved again")
    }

    func testPasteLastWritesALongDictationWholeUntilARelaunch() {
        let long = String(repeating: "word ", count: 5_000)
        let history = model()
        record(history, long)
        XCTAssertEqual(history.lastText(inMemory: nil), long)
        XCTAssertEqual(model().lastText(inMemory: nil)?.utf8.count, 16 * 1_024, "the entry keeps 16 KiB")
    }

    func testAnUnsavedDictationIsNotPastedOnceRemoved() throws {
        let history = model()
        record(history, "Saved")
        let blocker = URL(fileURLWithPath: file.path + ".tmp")
        try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: false)
        record(history, "Unsaved")
        let unsaved = try XCTUnwrap(history.recent().first).id
        XCTAssertThrowsError(try history.delete(unsaved))
        XCTAssertEqual(history.lastText(inMemory: nil), "Unsaved", "a failed delete keeps it")
        try FileManager.default.removeItem(at: blocker)
        try history.delete(unsaved)
        XCTAssertEqual(history.lastText(inMemory: "Unsaved"), "Saved")
        record(history, "Again")
        try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: false)
        record(history, "Unsaved again")
        try FileManager.default.removeItem(at: blocker)
        try history.clear()
        XCTAssertNil(history.lastText(inMemory: "Unsaved again"))
    }

    func testReplaceLastChangesTheNewestEntry() throws {
        let history = model()
        record(history, "um hello")
        history.replaceLast("Hello.")
        let entry = try XCTUnwrap(history.recent().first)
        XCTAssertEqual(entry.text, "Hello.")
        XCTAssertEqual(history.text(of: entry.id), "Hello.")
        XCTAssertEqual(history.entries(matching: "").count, 1)
    }

    func testDeleteRemovesOneEntry() throws {
        let history = model()
        record(history, "Keep")
        record(history, "Drop")
        try history.delete(try XCTUnwrap(history.recent().first).id)
        XCTAssertEqual(history.entries(matching: "").map(\.text), ["Keep"])
    }

    func testRecentListsAtMostFiveNewestFirst() {
        let history = model()
        for index in 1 ... 7 { record(history, "Dictation \(index)") }
        XCTAssertEqual(history.recent().map(\.text), (3 ... 7).reversed().map { "Dictation \($0)" })
    }
}
