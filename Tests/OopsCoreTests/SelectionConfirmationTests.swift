import ApplicationServices
import XCTest
@testable import OopsCore

final class SelectionConfirmationTests: XCTestCase {
    private let desired = NSRange(location: 4, length: 3)

    func testAcceptedWriteWaitsForDelayedSelectionSnapshot() throws {
        var clock = 0.0, writes = 0
        let reads = try SelectionConfirmation.require(desired, write: {
            writes += 1; return .success
        }, read: {
            clock >= 0.05 ? self.desired : NSRange(location: 0, length: 0)
        }, validate: {}, now: { clock }, pause: { clock += $0 })
        XCTAssertEqual(writes, 1, "Submit the action once; wait for acknowledgement rather than retrying writes")
        XCTAssertEqual(reads, 3)
        XCTAssertEqual(clock, 0.05, accuracy: 0.000001)
    }

    func testRejectedWriteDoesNotPollOrRetry() {
        var writes = 0, reads = 0
        XCTAssertThrowsError(try SelectionConfirmation.require(desired, write: {
            writes += 1; return .attributeUnsupported
        }, read: { reads += 1; return self.desired }, validate: {})) {
            XCTAssertEqual($0 as? SelectionConfirmation.Failure, .rejected(code: AXError.attributeUnsupported.rawValue))
        }
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(reads, 0)
    }

    func testDifferentSelectionTimesOutWithoutAcceptingIt() {
        var clock = 0.0, reads = 0
        let other = NSRange(location: 4, length: 2)
        XCTAssertThrowsError(try SelectionConfirmation.require(desired, write: { .success }, read: {
            reads += 1; return other
        }, validate: {}, now: { clock }, pause: { clock += $0 })) {
            XCTAssertEqual($0 as? SelectionConfirmation.Failure, .unconfirmed(expected: self.desired, observed: other))
        }
        XCTAssertLessThanOrEqual(clock, 0.300001)
        XCTAssertLessThanOrEqual(reads, 16)
    }

    func testChangedContextAbortsBeforeFurtherSelectionReads() {
        var clock = 0.0, reads = 0
        let moved = CorrectionError.message("Focus moved")
        XCTAssertThrowsError(try SelectionConfirmation.require(desired, write: { .success }, read: {
            reads += 1; return NSRange(location: 0, length: 0)
        }, validate: {
            if clock > 0 { throw moved }
        }, now: { clock }, pause: { clock += $0 })) {
            XCTAssertEqual($0 as? CorrectionError, moved)
        }
        XCTAssertEqual(reads, 1)
    }

    func testImmediateAcknowledgementDoesNotSleep() throws {
        var waits = 0
        let reads = try SelectionConfirmation.require(desired, write: { .success }, read: { self.desired },
            validate: {}, now: { 0 }, pause: { _ in waits += 1 })
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(waits, 0)
    }

    func testLateMatchingSnapshotDoesNotAuthorizePaste() {
        var clock = 0.0
        XCTAssertThrowsError(try SelectionConfirmation.require(desired, write: { .success }, read: {
            clock = 0.31; return self.desired
        }, validate: {}, now: { clock }, pause: { clock += $0 })) {
            XCTAssertEqual($0 as? SelectionConfirmation.Failure, .unconfirmed(expected: self.desired, observed: self.desired))
        }
    }
}
