import XCTest
@testable import OopsCore

/// Carried over from Hex's `src/paste.rs` tests (1b82cc0) for the rules ported in `PasteClipboard.swift`.
final class InsertPasteSequenceTests: XCTestCase {
    private struct Failure: Error, Equatable { let message: String }

    // rejected_commit_does_not_write_paste_or_restore
    func testRejectedCommitDoesNotWritePasteOrRestore() {
        var steps: [String] = []
        XCTAssertThrowsError(try PasteSequence.commitPrepared(prepare: { steps.append("prepare") }, commit: {
            steps.append("commit"); return false
        }, paste: { _ in
            steps.append("write")
            try PasteSequence.complete(post: { steps.append("post") }, scheduleRestore: { steps.append("restore") },
                                       wait: { _ in steps.append("settle") })
        })) { XCTAssertEqual($0 as? PasteSequence.Cancelled, PasteSequence.Cancelled()) }
        XCTAssertEqual(steps, ["prepare", "commit"])
    }

    // failed_preparation_does_not_commit_or_write
    func testFailedPreparationDoesNotCommitOrWrite() {
        XCTAssertThrowsError(try PasteSequence.commitPrepared(prepare: { throw Failure(message: "snapshot failed") }, commit: {
            XCTFail("failed preparation must remain cancellable"); return true
        }, paste: { (_: Void) in XCTFail("failed preparation must not mutate the clipboard") })) {
            XCTAssertEqual($0 as? Failure, Failure(message: "snapshot failed"))
        }
    }

    // sequential_pastes_settle_before_overwrite
    func testSequentialPastesSettleBeforeOverwrite() throws {
        var clipboard = "", pending = false, consumed: [String] = [], steps: [String] = []
        func paste(_ text: String) throws {
            clipboard = text
            try PasteSequence.complete(post: { pending = true; steps.append("post") }, scheduleRestore: { steps.append("restore") }, wait: { delay in
                XCTAssertEqual(delay, PasteSequence.settle)
                XCTAssertTrue(pending); pending = false
                consumed.append(clipboard); steps.append("settle")
            })
        }
        try paste("first")
        XCTAssertEqual(consumed, ["first"])
        try paste("second")
        XCTAssertEqual(consumed, ["first", "second"])
        XCTAssertEqual(steps, ["post", "restore", "settle", "post", "restore", "settle"])
    }

    // restoration_is_scheduled_after_a_stalled_post_completes
    func testRestorationIsScheduledAfterAStalledPostCompletes() throws {
        var elapsed = Duration.zero, restoreScheduledAt: Duration?
        try PasteSequence.complete(post: {
            elapsed = .seconds(1)
            XCTAssertNil(restoreScheduledAt)
        }, scheduleRestore: { restoreScheduledAt = elapsed }, wait: { elapsed += $0 })
        XCTAssertEqual(restoreScheduledAt, .seconds(1))
        XCTAssertEqual(elapsed, .seconds(1) + PasteSequence.settle)
    }

    // failed_paste_still_schedules_restore_without_settling
    func testFailedPasteStillSchedulesRestoreWithoutSettling() {
        var steps: [String] = []
        XCTAssertThrowsError(try PasteSequence.complete(post: {
            steps.append("post"); throw Failure(message: "post failed")
        }, scheduleRestore: { steps.append("restore") }, wait: { _ in steps.append("settle") })) {
            XCTAssertEqual($0 as? Failure, Failure(message: "post failed"))
        }
        XCTAssertEqual(steps, ["post", "restore"])
    }

    // rapid_pastes_keep_the_original_clipboard_for_the_latest_restore
    func testRapidPastesKeepTheOriginalClipboardForTheLatestRestore() {
        var restore = ClipboardRestore<String>()
        let first = restore.register("original image", previousChangeCount: 10, insertedChangeCount: 12)
        let second = restore.register("first insert", previousChangeCount: 12, insertedChangeCount: 14)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(restore.original, "original image")
        XCTAssertEqual(restore.lastChangeCount, 14)
        // The restore thread's rule: the first paste's restore stands down, the latest gives back the original.
        XCTAssertNil(restore.take(generation: first, changeCount: 14))
        XCTAssertEqual(restore.take(generation: second, changeCount: 14), "original image")
        XCTAssertNil(restore.original); XCTAssertNil(restore.lastChangeCount)
    }

    /// The restore thread in `paste_through_clipboard`: a pasteboard that moved on since the paste holds
    /// something newer, which is kept, and nothing saved comes back later either.
    func testSomethingCopiedSinceThePasteIsKept() {
        var restore = ClipboardRestore<String>()
        let generation = restore.register("before", previousChangeCount: 10, insertedChangeCount: 12)
        XCTAssertNil(restore.take(generation: generation, changeCount: 13))
        XCTAssertNil(restore.original); XCTAssertNil(restore.lastChangeCount)
        XCTAssertNil(restore.take(generation: generation, changeCount: 12))
        // The next paste saves what is there now.
        let next = restore.register("copied meanwhile", previousChangeCount: 13, insertedChangeCount: 15)
        XCTAssertEqual(restore.take(generation: next, changeCount: 15), "copied meanwhile")
    }
}
