import AppKit
import SwiftUI
import OopsCore

/// Providers, a page inside General: the list of connections, and one connection's detail pushed in place. The
/// list reads only the store; ChatGPT's own views observe `Preferences` inside its detail.
struct ProvidersPage: View {
    let store: ProviderStore
    let preferences: Preferences
    /// Back to General; a detail's own header goes back to this list.
    let back: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .top) {
            // A draft keeps its id when saved, so Add turns it into its detail page in place.
            if let provider = store.openProvider.flatMap(store.provider) ?? store.draft {
                ProviderDetail(provider: provider, store: store, preferences: preferences)
                    .id(provider.id)
                    .drillPane(edge: 1, reduceMotion: reduceMotion)
            } else {
                list.drillPane(edge: -1, reduceMotion: reduceMotion)
            }
        }
        .animation(SettingsMotion.drill(reduceMotion), value: store.openProvider ?? store.draft?.id)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 20) {
            DrillHeader(title: "Providers", parent: "General", back: back) {
                Image(systemName: ProvidersRow.symbol).font(.system(size: 18, weight: .medium))
            }
            ProviderSections(store: store, preferences: preferences)
        }
    }
}

/// A list row: mark, name and its current state. Keyboard focus shows as a soft highlight instead of the system ring.
struct ProviderRow: View {
    let provider: Provider
    let status: ProviderStore.Status
    /// Dictation's OpenAI key and nothing more: tagged as the model switches tag a voice model.
    var voice = false
    let open: () -> Void
    @FocusState private var focused: Bool
    @Environment(\.isFocusEffectEnabled) private var focusVisible

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                ProviderMark(provider: provider, size: 24)
                Text(provider.name).fontWeight(.semibold).lineLimit(1)
                Spacer(minLength: 8)
                if voice { CapabilityTag(voice: true).help("Used only to transcribe dictation") }
                if status.busy {
                    ProgressView().controlSize(.small).accessibilityLabel(status.text)
                } else {
                    StatusBadge(status.text, ok: status.ok).fixedSize()
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
