import Carbon
@testable import Oops
import OopsCore
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

    func testFixSwitchedOffRegistersNothingAndReportsNothing() {
        XCTAssertEqual(ShortcutSettings.registration(.correct, shortcut: nil, dictation: true, off: true), .off)
        XCTAssertEqual(ShortcutSettings.registration(.correct, shortcut: fixDefault, dictation: true, off: true), .off)
    }

    func testOnlyAFeaturesOwnShortcutIsItsSwitch() {
        XCTAssertTrue(ShortcutSettings.Action.dictate.isSwitch)
        XCTAssertFalse(ShortcutSettings.Action.dictateAndCleanUp.isSwitch, "Turn on records Dictate's shortcut, not this one")
        XCTAssertEqual(ShortcutSettings.Action.dictateAndCleanUp.tab, .dictate)
    }

    func testTwoActionsCannotShareAChord() {
        let both: [ShortcutSettings.Action: Shortcut] = [.correct: fixDefault, .dictate: chord]
        XCTAssertEqual(ShortcutSettings.clash(.dictate, fixDefault, with: both), .correct)
        XCTAssertEqual(ShortcutSettings.clash(.correct, chord, with: both), .dictate)
        XCTAssertNil(ShortcutSettings.clash(.dictate, chord, with: both), "its own chord again")
    }

    func testActionsHasNoDefaultAndIsItsFeaturesSwitch() {
        XCTAssertNil(ShortcutSettings.defaultShortcut(.actions, w: 13))
        XCTAssertEqual(ShortcutSettings.registration(.actions, shortcut: nil, dictation: true), .off)
        XCTAssertEqual(ShortcutSettings.registration(.actions, shortcut: chord, dictation: true), .chord(chord))
        XCTAssertTrue(ShortcutSettings.Action.actions.isSwitch)
        XCTAssertEqual(ShortcutSettings.Action.actions.tab, .actions)
    }

    func testActionsIsUnsetWithoutItsDebugSwitch() {
        XCTAssertFalse(ShortcutSettings.isAvailable(.actions, actions: false))
        XCTAssertTrue(ShortcutSettings.isAvailable(.actions, actions: true))
        XCTAssertTrue(ShortcutSettings.isAvailable(.correct, actions: false))
        XCTAssertTrue(ShortcutSettings.isAvailable(.dictate, actions: false))
    }

    func testHotkeyIdentitiesKeepTheirPlaces() {
        let router = HotkeyRouter(ShortcutSettings.Action.allCases)
        XCTAssertEqual(router.identity(of: .correct), 1)
        XCTAssertEqual(router.identity(of: .dictate), 2)
        XCTAssertEqual(router.identity(of: .dictateAndCleanUp), 3)
        XCTAssertEqual(router.identity(of: .actions), 4)
    }

    func testActionsClashesLikeAnyOther() {
        XCTAssertEqual(ShortcutSettings.clash(.actions, chord, with: [.dictate: chord]), .dictate)
    }
}
