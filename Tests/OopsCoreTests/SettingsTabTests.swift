import XCTest
@testable import OopsCore

final class SettingsTabTests: XCTestCase {
    func testActionsOffShowsFourTabsInOrder() {
        XCTAssertEqual(SettingsTab.visible(actions: false), [.general, .fix, .dictate, .providers])
    }
    func testActionsOnShowsFiveTabsInOrder() {
        XCTAssertEqual(SettingsTab.visible(actions: true), [.general, .fix, .dictate, .actions, .providers])
    }
    func testLaunchNamesOpenTheTabHoldingThatPage() {
        let all = SettingsTab.visible(actions: true)
        for name in ["try", "customize", "apps", "fix"] { XCTAssertEqual(SettingsTab.launch(name, visible: all), .fix, name) }
        for name in ["about", "stats", "changelog", "debug", "general", "nonsense"] {
            XCTAssertEqual(SettingsTab.launch(name, visible: all), .general, name)
        }
        XCTAssertEqual(SettingsTab.launch("provider", visible: all), .providers)
        for name in ["dictate", "dictation", "history"] { XCTAssertEqual(SettingsTab.launch(name, visible: all), .dictate, name) }
        XCTAssertEqual(SettingsTab.launch(nil, visible: all), .general)
    }
    func testHiddenTabsNeverOpen() {
        let four = SettingsTab.visible(actions: false)
        XCTAssertEqual(SettingsTab.launch("actions", visible: four), .general)
    }
    func testTabsSlideFromTheirSideOfTheVisibleOrder() {
        let four = SettingsTab.visible(actions: false)
        XCTAssertEqual(SettingsTab.side(of: .general, shown: .fix, in: four), -1)
        XCTAssertEqual(SettingsTab.side(of: .fix, shown: .fix, in: four), 0)
        XCTAssertEqual(SettingsTab.side(of: .providers, shown: .fix, in: four), 1)
    }
}
