import AppKit
import OopsCore
import SwiftUI

/// Providers' list: one card, a section for each kind of connection with its own way to add one. ChatGPT and
/// Claude Code show their branded buttons until they work, then a row like the others.
struct ProviderSections: View {
    let store: ProviderStore
    let preferences: Preferences

    var body: some View {
        let voice = store.speechOnlyID
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Provider.Category.allCases, id: \.self) { category in
                if category != .account { SettingsDivider().padding(.vertical, 8) }
                heading(category).padding(.top, category == .account ? 10 : 2)
                ForEach(store.providers.filter { $0.category == category }) { entry($0, voice: voice) }
                switch category {
                case .account: EmptyView()
                case .agent: if store.provider("claude-code") == nil { ClaudeCodeEntry(store: store) }
                case .api: AddAPIMenu(store: store)
                }
            }
        }
        .padding(.vertical, -6)
        .settingsSurface()
    }

    @ViewBuilder private func entry(_ provider: Provider, voice: String?) -> some View {
        // Only a sign-in known to be missing gets the button. One being read shows as Checking, and one needing
        // renewal is on record: both stay a row, and the page says to sign in again.
        if provider.kind == .chatGPT, store.chatGPTOnRecord == false {
            ChatGPTEntry(preferences: preferences)
        } else if provider.kind == .claudeCode, ClaudeCodeEntry.need(added: true, health: store.health[provider.id]) != nil {
            ClaudeCodeEntry(store: store)
        } else {
            ProviderRow(provider: provider, status: store.status(provider.id), voice: provider.id == voice) {
                store.openProvider = provider.id
            }
        }
    }

    private func heading(_ category: Provider.Category) -> some View {
        let (title, tip) = switch category {
        case .account: ("Accounts", "A plan you sign in to, such as ChatGPT’s: Oops counts toward its usage limits, with nothing more to pay.")
        case .agent: ("Agents on this Mac", "An app installed on this Mac, such as Claude Code, that Oops runs with your sign-in: its plan pays.")
        case .api: ("APIs", "Any OpenAI-compatible service reached with an API key: it bills you for what you use, and a local server is free.")
        }
        return HStack(spacing: 2) {
            Text(title).font(.system(size: 12, weight: .semibold)).secondaryText().accessibilityAddTraits(.isHeader)
            InfoTip(title, tip)
        }
    }
}

/// ChatGPT until signed in: OpenAI's own button, which signs in from here, and Cancel while the browser has it, so a
/// closed tab never leaves the button waiting.
private struct ChatGPTEntry: View {
    @ObservedObject var preferences: Preferences

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                ContinueWithChatGPTButton(loading: preferences.signingIn, listed: true) { preferences.signInWithChatGPT() }
                if preferences.signingIn { Button("Cancel") { preferences.cancelSignIn() }.buttonStyle(.settingsGlass) }
            }
            if let message = preferences.chatGPTMessage { ChatGPTNotice(message) }
        }
        .padding(.vertical, 6)
    }
}

/// Claude Code until it works: Anthropic's orange button, named for what it does, beside what is wrong once added.
struct ClaudeCodeEntry: View {
    let store: ProviderStore

    /// Not in Oops yet: add it, which checks it. Not installed: the setup page in the browser. Signed out: sign in, in
    /// Terminal. Nil once it works or is being checked, when it is a row.
    static func need(added: Bool, health: ProviderStore.Health?) -> ClaudeCodeButton.Need? {
        guard added else { return .add }
        switch health {
        case .notInstalled?: return .install
        case .signedOut?: return .signIn
        default: return nil
        }
    }

    var body: some View {
        let added = store.provider("claude-code") != nil, need = Self.need(added: added, health: store.health["claude-code"]) ?? .add
        HStack(spacing: 12) {
            ClaudeCodeButton(need: need) {
                switch need {
                case .add: _ = store.addClaudeCode()
                case .install: NSWorkspace.shared.open(ClaudeCodeSignIn.install)
                case .signIn: store.signInToClaude()
                }
                // Its page too, where Check again and Remove are once it's back from the browser or Terminal.
                store.openProvider = "claude-code"
            }
            Spacer(minLength: 8)
            if added, let problem = store.problem("claude-code") { StatusBadge(problem, ok: false).fixedSize() }
        }
        .padding(.vertical, 6)
    }
}

/// Adds an API provider: a preset fills its page in, Custom leaves it blank for any other OpenAI-compatible API.
private struct AddAPIMenu: View {
    let store: ProviderStore

    var body: some View {
        Menu {
            ForEach(ProviderPreset.all) { preset in
                Button { store.startDraft(); store.chooseDraftPreset(preset) } label: {
                    Label { Text(preset.name) } icon: { MenuIcon.image(preset.logoAsset, template: true) }
                }
            }
            Divider()
            Button { store.startDraft() } label: { Label { Text("Custom") } icon: { MenuIcon.symbol("server.rack") } }
        } label: {
            HStack(spacing: 12) {
                // Monochrome like the provider marks above it.
                Image(systemName: "plus.circle.fill").font(.system(size: 22)).foregroundStyle(.primary)
                    .frame(width: 24).accessibilityHidden(true)
                Text("Add API provider").fontWeight(.semibold)
                Spacer()
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .semibold)).secondaryText()
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }
}
