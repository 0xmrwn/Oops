import OopsCore
import SwiftUI

/// Providers' list: one card, a section for each kind of connection with its own way to add one. ChatGPT and
/// Claude Code show their branded buttons until they work, then a row like the others.
struct ProviderSections: View {
    let store: ProviderStore
    let preferences: Preferences

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Provider.Category.allCases, id: \.self) { category in
                if category != .account { SettingsDivider().padding(.vertical, 8) }
                heading(category).padding(.top, category == .account ? 10 : 2)
                ForEach(store.providers.filter { $0.category == category }) { entry($0) }
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

    @ViewBuilder private func entry(_ provider: Provider) -> some View {
        let health = store.health[provider.id]
        // A ChatGPT sign-in needing renewal is on record: it stays a row, its page says to sign in again.
        if provider.kind == .chatGPT, !ProviderOverview.isConfigured(.chatGPT, chatGPTOnRecord: store.chatGPTOnRecord) {
            ChatGPTEntry(preferences: preferences)
        } else if provider.kind == .claudeCode, health == .notInstalled || health == .signedOut {
            ClaudeCodeEntry(store: store)
        } else {
            ProviderRow(provider: provider, status: store.status(provider.id), voice: store.speechOnly(provider, local: .shared)) {
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

/// ChatGPT until signed in: OpenAI's own button, which signs in from here.
private struct ChatGPTEntry: View {
    @ObservedObject var preferences: Preferences

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ContinueWithChatGPTButton(loading: preferences.signingIn, listed: true) { preferences.signInWithChatGPT() }
            if let message = preferences.chatGPTMessage { ChatGPTNotice(message) }
        }
        .padding(.vertical, 6)
    }
}

/// Claude Code until it works: Anthropic's orange button, beside what is wrong once it has been added. It opens
/// Claude Code's page, where installing and signing in happen.
private struct ClaudeCodeEntry: View {
    let store: ProviderStore

    var body: some View {
        let added = store.provider("claude-code") != nil
        HStack(spacing: 12) {
            ClaudeCodeButton(need: added && store.health["claude-code"] == .signedOut ? .signIn : .install) {
                store.openProvider = store.addClaudeCode()
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
