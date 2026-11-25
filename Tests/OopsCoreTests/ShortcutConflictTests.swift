import XCTest
@testable import OopsCore

final class ShortcutConflictTests: XCTestCase {
    private let start = ContinuousClock.now
    private let hyper: UInt32 = 0x0100 | 0x0200 | 0x0800 | 0x1000
    private let d: UInt16 = 2
    /// ⌘ and ⌃, held while the chord's key goes down.
    private let modifiersDown: Set<UInt16> = [55, 59]

    private func at(_ milliseconds: Int) -> ContinuousClock.Instant { start + .milliseconds(milliseconds) }

    func testAChordThatReachesTheRecorderIsNoConflict() {
        var watch = ShortcutConflict(alreadyDown: [])
        XCTAssertNil(watch.sample(down: modifiersDown.union([d]), modifiers: hyper, at: at(0)))
        watch.heard(d)
        for time in stride(from: 30, through: 600, by: 30) { XCTAssertNil(watch.sample(down: modifiersDown.union([d]), modifiers: hyper, at: at(time))) }
    }

    func testAKeySeenDownThatNeverArrivesIsTakenAndNamed() {
        var watch = ShortcutConflict(alreadyDown: [])
        XCTAssertNil(watch.sample(down: modifiersDown.union([d]), modifiers: hyper, at: at(0)))
        XCTAssertNil(watch.sample(down: modifiersDown.union([d]), modifiers: hyper, at: at(200)))
        XCTAssertEqual(watch.sample(down: modifiersDown, modifiers: hyper, at: at(260)), .init(keyCode: d, modifiers: hyper))
        // Once per press.
        XCTAssertNil(watch.sample(down: modifiersDown.union([d]), modifiers: hyper, at: at(600)))
    }

    func testAKeyDownArrivingLateInsideTheWindowIsNoConflict() {
        var watch = ShortcutConflict(alreadyDown: [])
        XCTAssertNil(watch.sample(down: modifiersDown.union([d]), modifiers: hyper, at: at(0)))
        XCTAssertNil(watch.sample(down: modifiersDown.union([d]), modifiers: hyper, at: at(200)))
        watch.heard(d)
        XCTAssertNil(watch.sample(down: modifiersDown.union([d]), modifiers: hyper, at: at(400)))
    }

    func testModifiersAloneAreNoConflict() {
        var watch = ShortcutConflict(alreadyDown: [])
        for time in stride(from: 0, through: 600, by: 30) { XCTAssertNil(watch.sample(down: modifiersDown, modifiers: hyper, at: at(time))) }
        XCTAssertNil(watch.sample(down: [], modifiers: 0, at: at(700)))
    }

    /// A key held long repeats its key-down; it is one press, heard once, never reported.
    func testAHeldKeyThatRepeatsIsOnePress() {
        var watch = ShortcutConflict(alreadyDown: [])
        _ = watch.sample(down: modifiersDown.union([d]), modifiers: hyper, at: at(0))
        watch.heard(d)
        for time in stride(from: 30, through: 1500, by: 30) {
            watch.heard(d)
            XCTAssertNil(watch.sample(down: modifiersDown.union([d]), modifiers: hyper, at: at(time)))
        }
    }

    /// Escape alone (and any key without ⌃, ⌥ or ⌘) is not a shortcut, taken or not.
    func testEscapeAloneOrAPlainKeyIsNoConflict() {
        var watch = ShortcutConflict(alreadyDown: [])
        for time in stride(from: 0, through: 600, by: 30) { XCTAssertNil(watch.sample(down: [53], modifiers: 0, at: at(time))) }
        for time in stride(from: 700, through: 1300, by: 30) { XCTAssertNil(watch.sample(down: [56, d], modifiers: 0x0200, at: at(time))) }
    }

    func testEscapeWithCommandTakenIsAConflict() {
        var watch = ShortcutConflict(alreadyDown: [])
        _ = watch.sample(down: [55, 53], modifiers: 0x0100, at: at(0))
        XCTAssertEqual(watch.sample(down: [55, 53], modifiers: 0x0100, at: at(300)), .init(keyCode: 53, modifiers: 0x0100))
    }

    /// A key down before recording began (a remapper can leave one set) counts only once it has come up.
    func testAKeyAlreadyDownIsIgnoredUntilItComesUp() {
        var watch = ShortcutConflict(alreadyDown: [d])
        for time in stride(from: 0, through: 600, by: 30) { XCTAssertNil(watch.sample(down: modifiersDown.union([d]), modifiers: hyper, at: at(time))) }
        XCTAssertNil(watch.sample(down: modifiersDown, modifiers: hyper, at: at(630)))
        XCTAssertNil(watch.sample(down: modifiersDown.union([d]), modifiers: hyper, at: at(660)))
        XCTAssertEqual(watch.sample(down: modifiersDown.union([d]), modifiers: hyper, at: at(930)), .init(keyCode: d, modifiers: hyper))
    }

    /// A modifier that joins while the key is still waiting belongs to the chord.
    func testModifiersSeenWhileWaitingJoinTheChord() {
        var watch = ShortcutConflict(alreadyDown: [])
        _ = watch.sample(down: [55, d], modifiers: 0x0100, at: at(0))
        XCTAssertEqual(watch.sample(down: [55, 59, d], modifiers: 0x0100 | 0x1000, at: at(260)), .init(keyCode: d, modifiers: 0x0100 | 0x1000))
    }
}
