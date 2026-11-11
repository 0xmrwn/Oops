import OopsCore
import SwiftUI

extension SettingsTab {
    /// The tabs this build shows: Dictate and Actions only while their debug switch is on.
    static var shown: [Self] { visible(dictation: DebugFlags.dictation, actions: DebugFlags.actions) }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .fix: ShortcutSettings.Action.correct.symbol
        case .dictate: "mic"
        case .actions: "bolt"
        case .providers: "sparkles"
        }
    }
}

/// The tab bar: a capsule track spanning the content, with one Liquid Glass pill that slides to
/// the chosen tab on the page spring. The pill is a single view that only moves: inserting a new
/// pill in each tab on every click cost a glass layer's creation and teardown per switch.
/// ⌘1…n switch tabs; tabs are not keyboard focus stops, so no focus ring lands on them when
/// the window opens.
struct SettingsTabBar: View {
    let tabs: [SettingsTab]
    @Binding var selection: SettingsTab
    @Environment(\.colorScheme) private var colorScheme
    private static let inset: CGFloat = 4, gap: CGFloat = 4

    var body: some View {
        HStack(spacing: Self.gap) {
            ForEach(Array(tabs.enumerated()), id: \.element) { index, tab in
                let selected = tab == selection
                Button { selection = tab } label: {
                    Label(tab.rawValue, systemImage: tab.symbol)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary.opacity(selected ? 1 : 0.72))
                        .frame(maxWidth: .infinity, minHeight: 32)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                .help("\(tab.rawValue) · ⌘\(index + 1)")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(Self.inset)
        .background(alignment: .leading) { pill }
        .background {
            // The track: a faint plate with a hairline, so the glass pill is the only glass here. In
            // light the glass's edge stands in for the hairline, which a white backdrop washes out.
            Capsule().fill(.primary.opacity(colorScheme == .dark ? 0.07 : 0.05))
                .overlay { if colorScheme == .dark { Capsule().strokeBorder(.primary.opacity(0.1), lineWidth: 0.5) } }
                .glassEdge(Capsule())
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Settings section")
    }

    private var pill: some View {
        GeometryReader { proxy in
            let count = CGFloat(tabs.count)
            let width = (proxy.size.width - 2 * Self.inset - (count - 1) * Self.gap) / count
            let index = CGFloat(tabs.firstIndex(of: selection) ?? 0)
            Capsule().fill(.clear)
                .glassEffect(.regular.interactive(), in: .capsule)
                .glassEdge(Capsule(), outside: true)
                .frame(width: width, height: proxy.size.height - 2 * Self.inset)
                .offset(x: Self.inset + index * (width + Self.gap), y: Self.inset)
        }
    }
}

/// A waiting update, where the header's eyes were: the version on glass, leading to its card.
struct UpdatePill: View {
    let release: Updates.Release
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.circle.fill").font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.accentColor)
                Text("Update").fontWeight(.semibold)
                Text(release.version).secondaryText().monospacedDigit()
            }
            .font(.system(size: 13))
            .padding(.horizontal, 12).frame(height: 32)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .glassEdge(Capsule(), outside: true)
        .focusable(false)
        .pointerStyle(.link)
        .help("Oops \(release.version) is ready to install")
        .accessibilityLabel("Update to Oops \(release.version)")
    }
}
