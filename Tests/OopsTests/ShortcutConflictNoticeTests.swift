import AppKit
import Carbon
@testable import Oops
import XCTest

/// "Use anyway" beside the conflict it names only, and Try it's way back to a recorder that stays live.
@MainActor final class ShortcutConflictNoticeTests: XCTestCase {
    private let a = Shortcut(keyCode: 2, modifiers: Shortcut.hyper)
    private let b = Shortcut(keyCode: 3, modifiers: UInt32(cmdKey))

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        // No key clicks from the recorder under test; the argument domain is never saved.
        UserDefaults.standard.setVolatileDomain(["SoundsEnabled": false], forName: UserDefaults.argumentDomain)
    }

    override func tearDown() {
        UserDefaults.standard.removeVolatileDomain(forName: UserDefaults.argumentDomain)
        super.tearDown()
    }

    func testUseAnywayGoesWithTheConflictOnScreen() {
        XCTAssertEqual(ShortcutInUse.useAnyway(a, error: ShortcutInUse.settings(a), message: ShortcutInUse.settings), a)
        XCTAssertEqual(ShortcutInUse.useAnyway(a, error: ShortcutInUse.onboarding(a), message: ShortcutInUse.onboarding), a)
    }

    /// Chord A was taken, then B was refused because another Oops action has it: nothing to keep beside B's error.
    func testALaterRefusalOffersNothing() {
        let refusal = "\(b.label) is already in use by Dictate. Choose another shortcut."
        XCTAssertNil(ShortcutInUse.useAnyway(a, error: refusal, message: ShortcutInUse.settings))
        XCTAssertNil(ShortcutInUse.useAnyway(a, error: ShortcutInUse.settings(b), message: ShortcutInUse.settings))
        XCTAssertNil(ShortcutInUse.useAnyway(a, error: nil, message: ShortcutInUse.settings))
        XCTAssertNil(ShortcutInUse.useAnyway(nil, error: ShortcutInUse.settings(a), message: ShortcutInUse.settings))
    }

    func testTryItOwnsOnlyKeysItStillMirrors() {
        XCTAssertTrue(DictateTryStep.ownsKeys(listening: true, mirroring: true))
        XCTAssertTrue(DictateTryStep.ownsKeys(listening: false, mirroring: false))
        XCTAssertFalse(DictateTryStep.ownsKeys(listening: true, mirroring: false))
    }

    /// "Change shortcut" from Try it: the Shortcut step's recorder starts before Try it goes, or after. Either way
    /// the recorder is left listening, not mirroring.
    func testTheRecorderStaysLiveWhicheverViewGoesFirst() {
        for shortcutStepFirst in [true, false] {
            let keys = ShortcutStep(saves: false, action: .dictate)
            let tryIt = DictateTryStep(preferences: nil, keys: keys, speech: OnboardingSpeechModel(providers: nil))
            tryIt.start()
            XCTAssertTrue(keys.isMirroring)
            keys.change()
            if shortcutStepFirst { keys.start(); tryIt.stop() } else { tryIt.stop(); keys.start() }
            XCTAssertTrue(keys.isListening, "shortcut step first: \(shortcutStepFirst)")
            XCTAssertFalse(keys.isMirroring, "shortcut step first: \(shortcutStepFirst)")
            XCTAssertEqual(keys.phase, .recording)
            keys.stop()
        }
    }
}
