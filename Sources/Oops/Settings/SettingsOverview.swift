import OopsCore
import SwiftUI

/// General's map of the features: one row each with its shortcut, model and effort, or a Turn on button
/// while it has no shortcut. A row opens its tab.
struct FeatureOverview: View {
    let tabs: [SettingsTab]
    let store: ProviderStore
    let open: (SettingsTab) -> Void
    /// Opens the tab and starts recording its shortcut.
    let turnOn: (SettingsTab) -> Void

    var body: some View {
        let features = tabs.filter { [.fix, .dictate, .actions].contains($0) }
        VStack(spacing: 0) {
            ForEach(features, id: \.self) { tab in
                row(tab)
            }
        }
        .padding(.vertical, -6)
        .settingsSurface()
    }

    private func row(_ tab: SettingsTab) -> some View {
        // A feature with no shortcut is off.
        let shortcut = ShortcutSettings.Action.allCases.first { $0.tab == tab }.flatMap(ShortcutSettings.shared.shortcut)
        return HStack(spacing: 14) {
            Button { open(tab) } label: {
                HStack(spacing: 14) {
                    Image(systemName: tab.symbol).font(.system(size: 18, weight: .medium)).frame(width: 24)
                        .secondaryText().accessibilityHidden(true)
                    Text(tab.rawValue).fontWeight(.semibold)
                    Spacer(minLength: 8)
                    if let shortcut {
                        if tab == .fix { model }
                        HStack(spacing: 4) { ForEach(shortcut.keys, id: \.self, content: keycap) }
                            .accessibilityElement(children: .ignore).accessibilityLabel(shortcut.spoken)
                        Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).secondaryText()
                    }
                }
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open \(tab.rawValue)")
            // The shortcut is the switch: turning on opens the tab and records it there. Beside the row's own
            // button, not inside it, so it stays a control of its own.
            if shortcut == nil {
                Button("Turn on") { turnOn(tab) }.buttonStyle(.settingsGlass)
                    .accessibilityLabel("Turn on \(tab.rawValue)")
            }
        }
    }

    /// Fix's model and effort, as its picker shows them.
    @ViewBuilder private var model: some View {
        let model = store.currentModel
        HStack(spacing: 6) {
            if let provider = store.currentProvider, model != nil { ProviderMark(provider: provider, size: 14) }
            Text(model?.name ?? (store.pickerGroups.isEmpty ? "Add a provider" : "Choose a model"))
            if let effort = store.currentSettings.effort, model?.efforts.isEmpty == false {
                Text(ModelSelection.effortName(effort)).foregroundStyle(.secondary)
            }
        }
        .padding(.trailing, 6)
    }

    private func keycap(_ key: String) -> some View {
        Group {
            if key == Shortcut.hyperKey { HyperKeyLegend(size: 12.5, partSize: 9).padding(.vertical, 3) } else { Text(key).font(.system(size: 14, weight: .medium)) }
        }
        .frame(minWidth: 28, minHeight: 32).padding(.horizontal, key.count > 1 ? 8 : 0)
        .keycapFill(cornerRadius: 6)
    }
}
