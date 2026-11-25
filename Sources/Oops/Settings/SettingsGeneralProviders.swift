import OopsCore
import SwiftUI

/// General's way into Providers: the services set up, by their marks and a count past four.
struct ProvidersRow: View {
    static let symbol = "sparkles"
    let store: ProviderStore
    let open: () -> Void

    var body: some View {
        let connected = store.connectedProviders
        Button(action: open) {
            HStack(spacing: 14) {
                Image(systemName: Self.symbol).font(.system(size: 18, weight: .medium)).frame(width: 24)
                    .secondaryText().accessibilityHidden(true)
                Text("Providers").fontWeight(.semibold)
                Spacer(minLength: 8)
                if connected.isEmpty {
                    // The card at the top of General offers the way in, so this row doesn't ask again.
                    Text("None").secondaryText()
                } else {
                    HStack(spacing: 8) {
                        ForEach(connected.prefix(4)) { ProviderMark(provider: $0, size: 15) }
                        if connected.count > 4 { Text("+\(connected.count - 4)").secondaryText().monospacedDigit() }
                    }
                    .padding(.trailing, 4)
                }
                Chevron()
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open Providers")
        .accessibilityLabel((["Providers"] + (connected.isEmpty ? ["None"] : connected.map(\.name))).joined(separator: ", "))
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
