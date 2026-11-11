import XCTest
@testable import OopsCore

final class SettingsTabTests: XCTestCase {
    func testBothSwitchesOffShowGeneralFixProviders() {
        XCTAssertEqual(SettingsTab.visible(dictation: false, actions: false), [.general, .fix, .providers])
    }
    func testBothSwitchesOnShowFiveTabsInOrder() {
        XCTAssertEqual(SettingsTab.visible(dictation: true, actions: true), [.general, .fix, .dictate, .actions, .providers])
    }
    func testEachSwitchAddsOnlyItsTab() {
        XCTAssertEqual(SettingsTab.visible(dictation: true, actions: false), [.general, .fix, .dictate, .providers])
        XCTAssertEqual(SettingsTab.visible(dictation: false, actions: true), [.general, .fix, .actions, .providers])
    }
    func testLaunchNamesOpenTheTabHoldingThatPage() {
        let all = SettingsTab.visible(dictation: true, actions: true)
        for name in ["try", "customize", "apps", "fix"] { XCTAssertEqual(SettingsTab.launch(name, visible: all), .fix, name) }
        for name in ["about", "stats", "changelog", "debug", "general", "nonsense"] {
            XCTAssertEqual(SettingsTab.launch(name, visible: all), .general, name)
        }
        XCTAssertEqual(SettingsTab.launch("provider", visible: all), .providers)
        XCTAssertEqual(SettingsTab.launch("dictate", visible: all), .dictate)
        XCTAssertEqual(SettingsTab.launch(nil, visible: all), .general)
    }
    func testHiddenTabsNeverOpen() {
        let three = SettingsTab.visible(dictation: false, actions: false)
        XCTAssertEqual(SettingsTab.launch("dictate", visible: three), .general)
        XCTAssertEqual(SettingsTab.launch("actions", visible: three), .general)
    }
    func testTabsSlideFromTheirSideOfTheVisibleOrder() {
        let three = SettingsTab.visible(dictation: false, actions: false)
        XCTAssertEqual(SettingsTab.side(of: .general, shown: .fix, in: three), -1)
        XCTAssertEqual(SettingsTab.side(of: .fix, shown: .fix, in: three), 0)
        XCTAssertEqual(SettingsTab.side(of: .providers, shown: .fix, in: three), 1)
    }
}
