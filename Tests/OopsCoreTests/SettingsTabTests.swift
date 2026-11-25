import XCTest
@testable import OopsCore

final class SettingsTabTests: XCTestCase {
    func testActionsOffShowsThreeTabsInOrder() {
        XCTAssertEqual(SettingsTab.visible(actions: false), [.general, .fix, .dictate])
    }
    func testActionsOnShowsFourTabsInOrder() {
        XCTAssertEqual(SettingsTab.visible(actions: true), [.general, .fix, .dictate, .actions])
    }
    func testLaunchNamesOpenTheTabHoldingThatPage() {
        let all = SettingsTab.visible(actions: true)
        for name in ["try", "customize", "fix"] { XCTAssertEqual(SettingsTab.launch(name, visible: all), .fix, name) }
        for name in ["about", "stats", "changelog", "debug", "apps", "Apps", "general", "nonsense"] {
            XCTAssertEqual(SettingsTab.launch(name, visible: all), .general, name)
        }
        for name in ["dictate", "dictation", "history"] { XCTAssertEqual(SettingsTab.launch(name, visible: all), .dictate, name) }
        XCTAssertEqual(SettingsTab.launch("actions", visible: all), .actions)
        XCTAssertEqual(SettingsTab.launch(nil, visible: all), .general)
    }
    func testProvidersOpensGeneralWhichHoldsIt() {
        for visible in [SettingsTab.visible(actions: true), SettingsTab.visible(actions: false)] {
            for name in ["provider", "providers", "Providers"] { XCTAssertEqual(SettingsTab.launch(name, visible: visible), .general, name) }
        }
    }
    func testHiddenTabsNeverOpen() {
        let three = SettingsTab.visible(actions: false)
        XCTAssertEqual(SettingsTab.launch("actions", visible: three), .general)
    }
    func testTabsSlideFromTheirSideOfTheVisibleOrder() {
        let three = SettingsTab.visible(actions: false)
        XCTAssertEqual(SettingsTab.side(of: .general, shown: .fix, in: three), -1)
        XCTAssertEqual(SettingsTab.side(of: .fix, shown: .fix, in: three), 0)
        XCTAssertEqual(SettingsTab.side(of: .dictate, shown: .fix, in: three), 1)
    }
}
