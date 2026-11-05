import XCTest
@testable import OopsCore

final class ModifierReleaseTests: XCTestCase {
    func testAlreadyReleasedHasNoDelay() async throws {
        var pauses = 0
        let waits = try await ModifierRelease.wait(isReleased: { true }, now: { 0 }, pause: { _ in pauses += 1 })
        XCTAssertEqual(waits, 0)
        XCTAssertEqual(pauses, 0)
    }
    func testHeldHyperMustReleaseAndSettleBeforeGateMayStart() async throws {
        var clock = 0.0
        let waits = try await ModifierRelease.wait(isReleased: { clock >= 0.03 }, now: { clock }, pause: { clock += $0 })
        XCTAssertGreaterThanOrEqual(waits, 4)
        XCTAssertGreaterThanOrEqual(clock, 0.04)
    }
    func testBriefReleaseDoesNotPassWhileModifiersArePressedAgain() async throws {
        var clock = 0.0
        _ = try await ModifierRelease.wait(isReleased: { (clock >= 0.015 && clock < 0.025) || clock >= 0.04 },
            now: { clock }, pause: { clock += $0 })
        XCTAssertGreaterThanOrEqual(clock, 0.05)
    }
    func testHeldModifiersTimeOutWithoutAuthorizingSwap() async {
        var clock = 0.0
        do {
            _ = try await ModifierRelease.wait(isReleased: { false }, now: { clock }, pause: { clock += $0 })
            XCTFail("Held modifiers must not authorize a paste")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Release the shortcut’s keys"))
            XCTAssertLessThanOrEqual(clock, 1.000001)
        }
    }
    func testModifierNoKeyHoldsPassesOnceTheWaitIsUp() async throws {
        var clock = 0.0
        _ = try await ModifierRelease.wait(isReleased: { false }, keyboardReleased: { true }, now: { clock }, pause: { clock += $0 })
        XCTAssertGreaterThanOrEqual(clock, 0.99)
    }
    func testCancellationDuringWaitStopsTheOperation() async {
        do {
            _ = try await ModifierRelease.wait(isReleased: { false }, now: { 0 }, pause: { _ in throw CancellationError() })
            XCTFail("Cancelled wait must stop")
        } catch { XCTAssertTrue(error is CancellationError) }
    }
    func testLateReleaseDoesNotAuthorizeSwap() async {
        var clock = 0.0
        do {
            _ = try await ModifierRelease.wait(isReleased: { clock = 1.1; return true }, now: { clock }, pause: { clock += $0 })
            XCTFail("A late matching state must not authorize paste")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Release the shortcut’s keys")) }
    }
}
