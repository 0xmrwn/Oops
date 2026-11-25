import OopsCore
import SwiftUI

/// General's map of the features: one row each with its name, what it uses under it and its shortcut, or a
/// Turn on button while it has no shortcut. A row opens its tab.
struct FeatureOverview: View {
    let tabs: [SettingsTab]
    let store: ProviderStore
    let local: LocalModels
    let keyboards: KeyboardModelDriver
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
        let setup = shortcut == nil ? nil : setup(tab)
        return HStack(spacing: 14) {
            Button { open(tab) } label: {
                HStack(spacing: 14) {
                    Image(systemName: tab.symbol).font(.system(size: 18, weight: .medium)).frame(width: 24)
                        .secondaryText().accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tab.rawValue).fontWeight(.semibold)
                        // An off feature says so, so every row keeps one height.
                        if let setup { line(setup) } else { Text("Off").font(.callout).secondaryText() }
                    }
                    .layoutPriority(1)
                    Spacer(minLength: 8)
                    if let shortcut {
                        HStack(spacing: 4) { ForEach(shortcut.keys, id: \.self, content: keycap) }.fixedSize()
                        Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).secondaryText()
                    }
                }
                .padding(.vertical, 11)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // One sentence: the feature, what it uses, its shortcut.
            .accessibilityLabel([tab.rawValue, setup?.spoken ?? "Off", shortcut?.spoken].compactMap(\.self).joined(separator: ", "))
            // The shortcut is the switch: turning on opens the tab and records it there. Beside the row's own
            // button, not inside it, so it stays a control of its own.
            if shortcut == nil {
                Button("Turn on") { turnOn(tab) }.buttonStyle(.settingsGlass)
                    .accessibilityLabel("Turn on \(tab.rawValue)")
            }
        }
    }

    /// What the feature uses: Fix's model and effort, Dictate's speech model and language, how many actions there are.
    private func setup(_ tab: SettingsTab) -> FeatureSetup {
        switch tab {
        case .fix:
            guard let model = store.currentModel else {
                return FeatureSetup(value: store.pickerGroups.isEmpty ? "Add a provider" : "Choose a model", missing: true)
            }
            let effort = store.currentSettings.effort.flatMap { model.efforts.isEmpty ? nil : ModelSelection.effortName($0) }
            return FeatureSetup(mark: store.currentProvider.map(FeatureSetup.Mark.provider), value: model.name, detail: effort)
        case .dictate:
            guard let option = store.dictateOption(local) else { return FeatureSetup(value: "Choose a speech model", missing: true) }
            // Switching with the keyboard changes the language (and maybe the model) as the keyboard changes.
            let language = store.dictateLanguage(for: option)
            // Automatic as Dictate's own page says it: a model may detect only a few languages.
            let detail = keyboards.settings.enabled && !keyboards.settings.mappings.isEmpty ? "Follows keyboard"
                : DictateModelCard.name(language)
            return FeatureSetup(mark: .speech(DictateModelCard.maker(option.reference)), value: option.name, detail: detail)
        default:
            // Only here, so General with Actions hidden never loads (or writes) its library.
            let count = ActionLibraryModel.shared.library.actions.count
            return FeatureSetup(value: count == 0 ? "No actions" : count == 1 ? "1 action" : "\(count) actions")
        }
    }

    /// The quieter line under the name. The model's name gives way last, so the effort or language truncates first.
    @ViewBuilder private func line(_ setup: FeatureSetup) -> some View {
        if setup.missing {
            SetupToDo(title: setup.value).font(.callout)
        } else {
            HStack(spacing: 5) {
                switch setup.mark {
                case .provider(let provider): ProviderMark(provider: provider, size: 12).opacity(0.8)
                case .speech(let maker): SpeechModelMark(maker: maker, size: 12).opacity(0.8)
                case nil: EmptyView()
                }
                Text(setup.value).lineLimit(1).truncationMode(.middle).layoutPriority(1)
                if let detail = setup.detail {
                    Text("·")
                    Text(detail).lineLimit(1)
                }
            }
            .font(.callout).secondaryText()
        }
    }

    private func keycap(_ key: String) -> some View {
        Group {
            if key == Shortcut.hyperKey { HyperKeyLegend(size: 12.5, partSize: 9).padding(.vertical, 3) } else { Text(key).font(.system(size: 14, weight: .medium)) }
        }
        .frame(minWidth: 28, minHeight: 32).padding(.horizontal, key.count > 1 ? 8 : 0)
        .keycapFill(cornerRadius: 6)
    }
}

/// What a feature row shows under its name.
private struct FeatureSetup {
    enum Mark { case provider(Provider), speech(SpeechModelMaker?) }
    var mark: Mark?
    var value: String
    var detail: String?
    /// Setup is missing: the value is the step to take.
    var missing = false

    var spoken: String { [value, detail].compactMap(\.self).joined(separator: ", ") }
}

/// Missing setup, read as the step to take, in `StatusBadge`'s language.
struct SetupToDo: View {
    let title: String

    var body: some View {
        Label(title, systemImage: "exclamationmark.circle").lineLimit(1).fontWeight(.medium).foregroundStyle(.primary)
    }
}
