import Foundation
import OopsCore
import XCTest

/// The pre-roll a press starts with, from "Keep the microphone ready" and "While dictating".
final class DictationPreRollTests: XCTestCase {
    func testAPressKeepsThePreRollOnlyWhileTheMicrophoneIsReadyAndNothingSuppressesAudio() throws {
        let suite = "DictationPreRollTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }

        XCTAssertEqual(DictationAudioSettings.preRoll, .milliseconds(450))
        XCTAssertEqual(DictationAudioSettings.pressPreRoll(defaults), .zero, "off by default")
        for behavior in DictationWhileDictating.allCases {
            defaults.set(behavior.rawValue, forKey: DictationAudioSettings.whileDictatingKey)
            defaults.set(false, forKey: DictationAudioSettings.keepReadyKey)
            XCTAssertEqual(DictationAudioSettings.pressPreRoll(defaults), .zero, "\(behavior)")
            defaults.set(true, forKey: DictationAudioSettings.keepReadyKey)
            XCTAssertEqual(DictationAudioSettings.pressPreRoll(defaults), DictationAudioSettings.hotkeyPreRoll(behavior), "\(behavior)")
        }
    }
}
