import AppKit
import SwiftUI
import OopsCore

/// Providers: the list of connections, and one connection's detail pushed in place. The list reads
/// only the store; ChatGPT's own views observe `Preferences` inside its detail.
struct ProvidersPage: View {
    let store: ProviderStore
    let preferences: Preferences
    /// The models On this Mac lists; the app's own unless a snapshot passes another.
    var local: LocalModels?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .top) {
            // A draft keeps its id when saved, so Add turns it into its detail page in place.
            if let provider = store.openProvider.flatMap(store.provider) ?? store.draft {
                ProviderDetail(provider: provider, store: store, preferences: preferences)
                    .id(provider.id)
                    .transition(PaneSlideTransition(edge: 1, reduceMotion: reduceMotion))
            } else {
                list.transition(PaneSlideTransition(edge: -1, reduceMotion: reduceMotion))
            }
        }
        .animation(SettingsMotion.drill(reduceMotion), value: store.openProvider ?? store.draft?.id)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(spacing: 0) {
                ForEach(Array(store.providers.enumerated()), id: \.element.id) { index, provider in
                    if index > 0 { Divider() }
                    ProviderRow(provider: provider, status: store.status(provider.id)) { store.openProvider = provider.id }
                }
                Divider()
                addMenu
            }
            .padding(.vertical, -6)
            .settingsSurface()
            if DebugFlags.dictation { LocalModelsCard(store: store, local: local ?? .shared) }
        }
    }

    private var addMenu: some View {
        Menu {
            Toggle(isOn: .constant(true)) { Label { Text("ChatGPT") } icon: { MenuIcon.image("ChatGPTMarkBlack", template: true) } }
                .disabled(true)
            if store.provider("claude-code") == nil {
                Button { store.openProvider = store.addClaudeCode() } label: { Label { Text("Claude Code") } icon: { MenuIcon.image("ClaudeMark", template: true) } }
            } else {
                Toggle(isOn: .constant(true)) { Label { Text("Claude Code") } icon: { MenuIcon.image("ClaudeMark", template: true) } }.disabled(true)
            }
            Divider()
            Button { store.startDraft() } label: { Label { Text("API provider…") } icon: { MenuIcon.symbol("server.rack") } }
        } label: {
            HStack(spacing: 12) {
                // Monochrome like the provider marks above it.
                Image(systemName: "plus.circle.fill").font(.system(size: 22)).foregroundStyle(.primary)
                    .frame(width: 24).accessibilityHidden(true)
                Text("Add provider").fontWeight(.semibold)
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

/// A list row: mark, name and its current state. Keyboard focus shows as a soft highlight instead of the system ring.
private struct ProviderRow: View {
    let provider: Provider
    let status: ProviderStore.Status
    let open: () -> Void
    @FocusState private var focused: Bool
    @Environment(\.isFocusEffectEnabled) private var focusVisible

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                ProviderMark(provider: provider, size: 24)
                Text(provider.name).fontWeight(.semibold)
                Spacer(minLength: 8)
                if status.busy {
                    ProgressView().controlSize(.small).accessibilityLabel(status.text)
                } else {
                    StatusBadge(status.text, ok: status.ok)
                }
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).secondaryText()
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 8)
            .background(.primary.opacity(focused && focusVisible ? 0.07 : 0), in: .rect(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, -8)
        .focused($focused)
        .focusEffectDisabled()
        .accessibilityHint("Shows this provider’s connection and models")
    }
}
