@testable import Oops
import Testing

/// Claude Code's button in Providers says what pressing it does.
@MainActor struct ClaudeCodeEntryTests {
    @Test func `the button is named for what Claude Code needs, and gives way to a row`() {
        #expect(ClaudeCodeEntry.need(added: false, health: nil) == .add)
        #expect(ClaudeCodeEntry.need(added: false, health: .ready) == .add)
        #expect(ClaudeCodeEntry.need(added: true, health: .notInstalled) == .install)
        #expect(ClaudeCodeEntry.need(added: true, health: .signedOut) == .signIn)
        for health: ProviderStore.Health? in [nil, .checking, .ready, .unreachable("timeout")] {
            #expect(ClaudeCodeEntry.need(added: true, health: health) == nil)
        }
    }
}
