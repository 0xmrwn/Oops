import Carbon
@testable import Oops
import XCTest

/// Which actions register, with what, and that two of them never share a chord.
@MainActor final class ShortcutRulesTests: XCTestCase {
    private let fixDefault = Shortcut(keyCode: 13, modifiers: UInt32(controlKey | cmdKey))
    private let chord = Shortcut(keyCode: 2, modifiers: UInt32(optionKey | cmdKey))

    func testOnlyFixHasADefault() {
        XCTAssertEqual(ShortcutSettings.defaultShortcut(.correct, w: 13), fixDefault)
        XCTAssertNil(ShortcutSettings.defaultShortcut(.correct, w: nil), "a layout with no W")
        XCTAssertNil(ShortcutSettings.defaultShortcut(.dictate, w: 13))
    }

    func testAnActionWithoutAShortcutIsOffNotAFailure() {
        XCTAssertEqual(ShortcutSettings.registration(.dictate, shortcut: nil, dictation: true), .off)
        // "Dictate and clean up" is unset by default, and unset registers no second hotkey.
        XCTAssertNil(ShortcutSettings.defaultShortcut(.dictateAndCleanUp, w: 13))
        XCTAssertEqual(ShortcutSettings.registration(.dictateAndCleanUp, shortcut: nil, dictation: true), .off)
        XCTAssertEqual(ShortcutSettings.registration(.dictateAndCleanUp, shortcut: chord, dictation: true), .chord(chord))
        XCTAssertEqual(ShortcutSettings.registration(.dictateAndCleanUp, shortcut: chord, dictation: false), .off)
        XCTAssertEqual(ShortcutSettings.registration(.dictate, shortcut: chord, dictation: true), .chord(chord))
        // Fix keeps its message for a layout with no W.
        XCTAssertEqual(ShortcutSettings.registration(.correct, shortcut: nil, dictation: true), .noDefault)
        XCTAssertEqual(ShortcutSettings.registration(.correct, shortcut: fixDefault, dictation: false), .chord(fixDefault))
    }

    func testDictateRegistersOnlyWhileDictationIsOn() {
        XCTAssertEqual(ShortcutSettings.registration(.dictate, shortcut: chord, dictation: false), .off)
    }

    func testPasteLastDictationIsUnsetByDefaultAndRegistersOnlyOnceSet() {
        XCTAssertNil(ShortcutSettings.defaultShortcut(.pasteLast, w: 13))
        XCTAssertEqual(ShortcutSettings.registration(.pasteLast, shortcut: nil, dictation: true), .off, "unset: no hotkey")
        XCTAssertEqual(ShortcutSettings.registration(.pasteLast, shortcut: chord, dictation: true), .chord(chord))
        XCTAssertEqual(ShortcutSettings.registration(.pasteLast, shortcut: chord, dictation: false), .off)
        let both: [ShortcutSettings.Action: Shortcut] = [.dictate: chord]
        XCTAssertEqual(ShortcutSettings.clash(.pasteLast, chord, with: both, dictation: true), .dictate)
    }

    func testOnlyAFeaturesOwnShortcutIsItsSwitch() {
        XCTAssertTrue(ShortcutSettings.Action.dictate.isSwitch)
        XCTAssertFalse(ShortcutSettings.Action.pasteLast.isSwitch, "Turn on records Dictate's shortcut, not this one")
        XCTAssertFalse(ShortcutSettings.Action.dictateAndCleanUp.isSwitch, "Turn on records Dictate's shortcut, not this one")
        XCTAssertEqual(ShortcutSettings.Action.pasteLast.tab, .dictate)
    }

    func testTwoActionsCannotShareAChord() {
        let both: [ShortcutSettings.Action: Shortcut] = [.correct: fixDefault, .dictate: chord]
        XCTAssertEqual(ShortcutSettings.clash(.dictate, fixDefault, with: both, dictation: true), .correct)
        XCTAssertEqual(ShortcutSettings.clash(.correct, chord, with: both, dictation: true), .dictate)
        XCTAssertNil(ShortcutSettings.clash(.dictate, chord, with: both, dictation: true), "its own chord again")
        XCTAssertNil(ShortcutSettings.clash(.correct, chord, with: both, dictation: false), "Dictate isn't registered while off")
    }
}
