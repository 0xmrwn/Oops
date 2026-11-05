import XCTest
@testable import OopsCore

final class FocusWakeTests: XCTestCase {
    func testFocusedElementNeedsNoWakeOrDelay() throws {
        var wakes = 0, pauses = 0
        let result = try FocusWake.resolve(lookup: { "composer" }, wake: { wakes += 1 }, pause: { _ in pauses += 1 })
        XCTAssertEqual(result?.element, "composer"); XCTAssertEqual(result?.retries, 0)
        XCTAssertEqual(wakes, 0); XCTAssertEqual(pauses, 0)
    }
    func testDormantTreeIsWokenOnceAndFoundOnRetry() throws {
        var wakes = 0, lookups = 0, slept = 0.0
        let result = try FocusWake.resolve(lookup: { lookups += 1; return lookups >= 4 ? "composer" : nil },
                                           wake: { wakes += 1 }, pause: { slept += $0 })
        XCTAssertEqual(result?.retries, 3)
        XCTAssertEqual(wakes, 1)
        XCTAssertEqual(slept, 0.3, accuracy: 1e-9)
    }
    func testNoFocusGivesUpWithinOneSecond() throws {
        var slept = 0.0
        let result: (element: String, retries: Int)? = try FocusWake.resolve(lookup: { nil }, wake: {}, pause: { slept += $0 })
        XCTAssertNil(result)
        XCTAssertLessThanOrEqual(slept, 1.000001)
    }
    func testCancellationStopsRetrying() {
        var pauses = 0
        XCTAssertThrowsError(try FocusWake.resolve(lookup: { nil as String? }, wake: {},
                                                   check: { if pauses >= 2 { throw CancellationError() } },
                                                   pause: { _ in pauses += 1 }))
        XCTAssertEqual(pauses, 2)
    }
}
