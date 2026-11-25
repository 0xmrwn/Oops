@testable import Oops
import OopsCore
import Testing

struct GeneralDetailTests {
    @Test func `launch names open General's pages in any case`() {
        let tabs = SettingsTab.visible(actions: true)
        for name in ["provider", "providers", "Providers", "PROVIDERS"] {
            #expect(SettingsTab.launch(name, visible: tabs) == .general)
            #expect(GeneralDetail.launch(name) == .providers)
        }
        for name in ["apps", "Apps"] {
            #expect(SettingsTab.launch(name, visible: tabs) == .general)
            #expect(GeneralDetail.launch(name) == .apps)
        }
        #expect(GeneralDetail.launch("Stats") == .stats)
        #expect(GeneralDetail.launch("Debug") == .debug)
        #expect(GeneralDetail.launch("fix") == nil)
        #expect(GeneralDetail.launch(nil) == nil)
    }

    @Test func `turn off in apps counts the apps Oops is off in`() {
        #expect(TurnOffInAppsRow.summary(0) == "None")
        #expect(TurnOffInAppsRow.summary(1) == "1 app")
        #expect(TurnOffInAppsRow.summary(3) == "3 apps")
    }
}
