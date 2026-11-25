import XCTest
@testable import OopsCore

final class MissedReleaseTests: XCTestCase {
    func testAKeyStillDownInfersNothing() {
        var watch = MissedRelease<Int>()
        for time in 0 ..< 100 { XCTAssertNil(watch.sample(keyDown: true, at: time)) }
    }

    func testAKeyUpForOneSampleWaitsForTheRealRelease() {
        var watch = MissedRelease<Int>()
        XCTAssertNil(watch.sample(keyDown: true, at: 0))
        XCTAssertNil(watch.sample(keyDown: false, at: 1))
    }

    func testAKeyThatStaysUpIsReleasedWhenItFirstReadUp() {
        var watch = MissedRelease<Int>()
        _ = watch.sample(keyDown: true, at: 0)
        XCTAssertNil(watch.sample(keyDown: false, at: 7))
        XCTAssertEqual(watch.sample(keyDown: false, at: 8), 7)
    }

    func testAKeyDownAgainStartsOver() {
        var watch = MissedRelease<Int>()
        XCTAssertNil(watch.sample(keyDown: false, at: 1))
        XCTAssertNil(watch.sample(keyDown: true, at: 2))
        XCTAssertNil(watch.sample(keyDown: false, at: 3))
        XCTAssertEqual(watch.sample(keyDown: false, at: 4), 3)
    }

    /// The whole bound: a release the system never sends is told within this long of the key coming up.
    func testTheWaitIsBounded() {
        XCTAssertLessThanOrEqual(MissedRelease<Int>.interval * MissedRelease<Int>.confirmations, .milliseconds(150))
    }
}
