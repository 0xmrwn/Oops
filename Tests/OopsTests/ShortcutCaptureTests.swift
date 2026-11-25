import AppKit
import Carbon
@testable import Oops
import XCTest

/// What a recorder saves: the key-down that completes the chord, with the modifiers it carries.
final class ShortcutCaptureTests: XCTestCase {
    private let hyper: NSEvent.ModifierFlags = [.control, .option, .shift, .command]
    private let d: UInt16 = 2

    func testHyperAndAKeyRecordThatKeyWithAllFour() {
        XCTAssertEqual(ShortcutCapture(keyCode: d, flags: hyper, isRepeat: false), .record(Shortcut(keyCode: 2, modifiers: Shortcut.hyper)))
    }

    /// Only the key-down's own flags count: nothing held before it, or still arriving after it, changes the chord.
    func testTheModifiersAreTheKeyDownsOwn() {
        XCTAssertEqual(ShortcutCapture(keyCode: d, flags: [.control, .command], isRepeat: false),
                       .record(Shortcut(keyCode: 2, modifiers: UInt32(controlKey | cmdKey))))
    }

    func testFlagsThatAreNotModifiersAreDropped() {
        XCTAssertEqual(ShortcutCapture(keyCode: d, flags: hyper.union([.capsLock, .function, .numericPad]), isRepeat: false),
                       .record(Shortcut(keyCode: 2, modifiers: Shortcut.hyper)))
    }

    /// A repeat means the key was already down when recording heard it: its first press went elsewhere.
    func testARepeatCompletesNothing() {
        XCTAssertEqual(ShortcutCapture(keyCode: d, flags: hyper, isRepeat: true), .ignore)
    }

    func testShiftAloneOrNoModifierIsRefused() {
        XCTAssertEqual(ShortcutCapture(keyCode: d, flags: [.shift], isRepeat: false), .refuse)
        XCTAssertEqual(ShortcutCapture(keyCode: d, flags: [], isRepeat: false), .refuse)
    }

    func testEscapeAloneCancelsAndWithAModifierRecords() {
        XCTAssertEqual(ShortcutCapture(keyCode: 53, flags: [], isRepeat: false), .cancel)
        XCTAssertEqual(ShortcutCapture(keyCode: 53, flags: [], isRepeat: true), .cancel)
        XCTAssertEqual(ShortcutCapture(keyCode: 53, flags: [.command], isRepeat: false), .record(Shortcut(keyCode: 53, modifiers: UInt32(cmdKey))))
    }
}
