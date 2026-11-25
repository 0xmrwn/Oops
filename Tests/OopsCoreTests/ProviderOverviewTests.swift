import OopsCore
import Testing

struct ProviderOverviewTests {
    private let chatGPT = Provider.chatGPT(), claude = Provider.claudeCode()
    private let mistral = Provider.api(name: "Mistral", baseURL: "https://api.mistral.ai/v1", preset: "mistral")
    private let groq = Provider.api(name: "Groq", baseURL: "https://api.groq.com/openai/v1", preset: "groq")

    private func overview(_ providers: [Provider], chatGPT onRecord: Bool?,
                          _ standing: [String: ProviderOverview.Standing] = [:]) -> ProviderOverview {
        ProviderOverview(providers: providers, chatGPTOnRecord: onRecord) { standing[$0.id] ?? .usable }
    }

    @Test func `a never signed in ChatGPT is not set up`() {
        let fresh = overview([chatGPT], chatGPT: false)
        #expect(fresh.configured.isEmpty)
        #expect(fresh.noneSetUp)
    }

    @Test func `nothing set up is not claimed before ChatGPT's sign-in is read`() {
        let unread = overview([chatGPT], chatGPT: nil)
        #expect(unread.configured.isEmpty)
        #expect(!unread.noneSetUp)
        #expect(!overview([chatGPT, mistral], chatGPT: nil).noneSetUp)
    }

    @Test func `a sign-in on record, Claude Code and API providers are set up`() {
        let all = overview([chatGPT, claude, mistral], chatGPT: true)
        #expect(all.configured.map(\.provider.id) == [chatGPT.id, claude.id, mistral.id])
        #expect(overview([chatGPT, mistral], chatGPT: false).configured.map(\.provider.id) == [mistral.id])
    }

    @Test func `attention names one problem in its own words and counts several`() {
        #expect(overview([chatGPT, mistral], chatGPT: true).attention == nil)
        #expect(overview([chatGPT, mistral, groq], chatGPT: true, [groq.id: .problem("Can’t connect")]).attention == "Can’t connect")
        let two = overview([chatGPT, claude, groq], chatGPT: true, [claude.id: .problem("Signed out"), groq.id: .problem("Can’t connect")])
        #expect(two.attention == "2 need attention")
    }

    @Test func `unchecked is neither usable nor a problem`() {
        let checking = overview([chatGPT, mistral], chatGPT: false, [mistral.id: .unchecked])
        #expect(checking.configured.map(\.standing) == [.unchecked])
        #expect(checking.attention == nil)
        #expect(!checking.noneSetUp)
    }

    @Test func `each provider falls in one section, accounts then agents then APIs`() {
        let custom = Provider.api(name: "Work", baseURL: "https://llm.example.com/v1", preset: nil)
        #expect([chatGPT, claude, mistral, custom].map(\.category) == [.account, .agent, .api, .api])
        #expect(Provider.Category.allCases == [.account, .agent, .api])
    }
}
