import OopsCore
import SwiftUI

/// General's way into Providers: the services set up, by their marks and a count past four, and what needs attention
/// among them. Not shown while nothing is set up: the card at the top of General is the way in then.
struct ProvidersRow: View {
    static let symbol = "sparkles"
    let overview: ProviderOverview
    let open: () -> Void

    var body: some View {
        let configured = overview.configured.map(\.provider)
        Button(action: open) {
            HStack(spacing: 14) {
                Image(systemName: Self.symbol).font(.system(size: 18, weight: .medium)).frame(width: 24)
                    .secondaryText().accessibilityHidden(true)
                Text("Providers").fontWeight(.semibold)
                Spacer(minLength: 8)
                HStack(spacing: 8) {
                    ForEach(configured.prefix(4)) { ProviderMark(provider: $0, size: 15) }
                    if configured.count > 4 { Text("+\(configured.count - 4)").secondaryText().monospacedDigit() }
                }
                .padding(.trailing, 4)
                if let attention = overview.attention { StatusBadge(attention, ok: false).lineLimit(1) }
                Chevron()
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel((["Providers"] + configured.map(\.name) + [overview.attention].compactMap(\.self)).joined(separator: ", "))
        .accessibilityHint("Opens Providers")
        .padding(.vertical, -6)
        .settingsSurface()
    }
}

/// No provider set up: Fix, Actions and Clean up with AI have nothing to run with. Modelled on General's
/// Accessibility card; it goes once a provider is there.
struct ProviderSetupCard: View {
    let add: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Providers", systemImage: ProvidersRow.symbol).font(.headline)
                Spacer()
                StatusBadge("None set up", ok: false)
            }
            // The action on the trailing edge, as in a macOS dialog.
            HStack {
                Spacer()
                Button(action: add) { Label("Add a provider", systemImage: "plus") }
                    .buttonStyle(.glassProminent).tint(.accentColor).controlSize(.large)
            }
        }
        .settingsSurface()
    }
}
