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
        #expect(GeneralDetail.launch("Stats") == .stats)
        #expect(GeneralDetail.launch("Debug") == .debug)
        #expect(GeneralDetail.launch("fix") == nil)
        #expect(GeneralDetail.launch(nil) == nil)
    }
}
