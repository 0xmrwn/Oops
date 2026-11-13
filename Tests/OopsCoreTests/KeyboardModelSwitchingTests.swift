import XCTest
@testable import OopsCore

/// Hex's tests of keyboard model switching (`src/transcription/keyboard_model_switching.rs` at v3.4.0), each under
/// its upstream name in the Swift style. Model ids are Hex's wire names.
final class KeyboardModelSwitchingTests: XCTestCase {
    private let parakeetV3 = "parakeet_v3"
    private let whisper = "whisper_large_v3_turbo"
    private let parakeetUnifiedEnglish = "parakeet_unified_en"

    private func choice(_ model: String, _ language: String) -> KeyboardModelChoice {
        KeyboardModelChoice(modelID: model, language: language)
    }

    private func mapped(_ entries: [(String, KeyboardModelChoice)]) -> KeyboardModelSwitchSettings {
        KeyboardModelSwitchSettings(enabled: true, mappings: Dictionary(uniqueKeysWithValues: entries))
    }

    private var spanish: KeyboardModelChoice { choice(parakeetV3, "es") }

    func testAMappedStartupSourceDoesNotSwitchUntilItsMappingIsEdited() {
        let now = ContinuousClock.now
        var settings = mapped([("Spanish", spanish)])
        var switcher = KeyboardModelSwitcher(settings: settings, current: "Spanish")
        XCTAssertNil(switcher.takeDue(now: now + .seconds(1)))
        let whisperChoice = choice(whisper, "es")
        settings.mappings["Spanish"] = whisperChoice
        XCTAssertTrue(switcher.configure(settings, now: now))
        XCTAssertEqual(switcher.takeDue(now: now), whisperChoice)
    }

    func testSourceChangesAreDebouncedAndDuplicatesIgnored() {
        let now = ContinuousClock.now
        var switcher = KeyboardModelSwitcher(settings: mapped([("Spanish", spanish)]), current: "ABC")
        XCTAssertFalse(switcher.sourceChanged("ABC", now: now))
        XCTAssertNil(switcher.takeDue(now: now + .seconds(1)))
        XCTAssertTrue(switcher.sourceChanged("Spanish", now: now))
        XCTAssertNil(switcher.takeDue(now: now + .milliseconds(299)))
        XCTAssertEqual(switcher.takeDue(now: now + .milliseconds(300)), spanish)
        XCTAssertNil(switcher.takeDue(now: now + .seconds(1)))
    }

    func testALanguageOnlyEditOfTheActiveMappingAppliesNow() {
        let now = ContinuousClock.now
        var settings = mapped([("Russian", choice(parakeetV3, "en"))])
        var switcher = KeyboardModelSwitcher(settings: settings, current: "Russian")
        let russian = choice(parakeetV3, "ru")
        settings.mappings["Russian"] = russian
        XCTAssertTrue(switcher.configure(settings, now: now))
        XCTAssertEqual(switcher.takeDue(now: now), russian)
    }

    func testAManualChoiceCancelsThePendingSwitchUntilAnotherSourceChange() {
        let now = ContinuousClock.now
        var switcher = KeyboardModelSwitcher(settings: mapped([("Spanish", spanish)]), current: "ABC")
        _ = switcher.sourceChanged("Spanish", now: now)
        switcher.manualChoice()
        XCTAssertNil(switcher.takeDue(now: now + .seconds(1)))
        // Duplicate native notifications must not undo the manual choice.
        XCTAssertFalse(switcher.sourceChanged("Spanish", now: now))
        XCTAssertNil(switcher.takeDue(now: now + .seconds(2)))
    }

    func testEnablingOrEditingTheActiveMappingAppliesNowButOtherEditsDoNot() {
        let now = ContinuousClock.now
        var switcher = KeyboardModelSwitcher(settings: KeyboardModelSwitchSettings(), current: nil)
        var settings = mapped([("Spanish", spanish)])
        // Enabling waits for the observer's report of the current source.
        XCTAssertTrue(switcher.configure(settings, now: now))
        XCTAssertNil(switcher.takeDue(now: now))
        XCTAssertTrue(switcher.sourceChanged("Spanish", now: now))
        XCTAssertEqual(switcher.takeDue(now: now + KeyboardModelSwitcher.debounce), spanish)
        settings.mappings["ABC"] = choice(parakeetUnifiedEnglish, "en")
        XCTAssertFalse(switcher.configure(settings, now: now))
        XCTAssertNil(switcher.takeDue(now: now))
        let whisperChoice = choice(whisper, "es")
        settings.mappings["Spanish"] = whisperChoice
        XCTAssertTrue(switcher.configure(settings, now: now))
        XCTAssertEqual(switcher.takeDue(now: now), whisperChoice)
        settings.enabled = false
        XCTAssertTrue(switcher.configure(settings, now: now))
        XCTAssertNil(switcher.takeDue(now: now))
    }

    func testCyclingPastASourceOnlySwitchesToTheLastMapping() {
        let now = ContinuousClock.now
        let french = choice(whisper, "fr")
        var switcher = KeyboardModelSwitcher(settings: mapped([("French", french), ("Spanish", spanish)]), current: "ABC")
        _ = switcher.sourceChanged("French", now: now)
        _ = switcher.sourceChanged("Spanish", now: now + .milliseconds(100))
        XCTAssertNil(switcher.takeDue(now: now + .milliseconds(300)))
        XCTAssertEqual(switcher.takeDue(now: now + .milliseconds(400)), spanish)
        _ = switcher.sourceChanged("French", now: now + .seconds(1))
        _ = switcher.sourceChanged("ABC", now: now + .milliseconds(1100))
        XCTAssertNil(switcher.takeDue(now: now + .seconds(2)))
    }

    func testTurningOffTheFeatureCancelsADebouncedSwitchAndForgetsTheSource() {
        let now = ContinuousClock.now
        var settings = mapped([("Spanish", spanish)])
        var switcher = KeyboardModelSwitcher(settings: settings, current: "ABC")
        _ = switcher.sourceChanged("Spanish", now: now)
        settings.enabled = false
        _ = switcher.configure(settings, now: now + .milliseconds(100))
        XCTAssertNil(switcher.takeDue(now: now + .seconds(1)))
        XCTAssertFalse(switcher.sourceChanged("ABC", now: now))
        XCTAssertFalse(switcher.sourceChanged("Spanish", now: now))
        XCTAssertNil(switcher.takeDue(now: now + .seconds(2)))
        // Turning it back on does not act on the source seen before.
        settings.enabled = true
        _ = switcher.configure(settings, now: now)
        XCTAssertNil(switcher.takeDue(now: now + .seconds(3)))
    }

    func testANewMappingStartsInTheSourcesLanguageWhenTheModelHasIt() throws {
        let source = KeyboardInputSource(id: "com.apple.keylayout.Russian", name: "Russian", languages: ["ru", "en-US"])
        let v3 = try XCTUnwrap(SpeechModelCatalog.model(id: parakeetV3))
        let english = try XCTUnwrap(SpeechModelCatalog.model(id: parakeetUnifiedEnglish))
        XCTAssertEqual(source.language(for: v3, fallback: "en"), "ru")
        XCTAssertEqual(source.language(for: english, fallback: "en"), "en")
        let unknown = KeyboardInputSource(id: source.id, name: source.name, languages: ["xx"])
        XCTAssertEqual(unknown.language(for: v3, fallback: "de"), "de")
    }
}
