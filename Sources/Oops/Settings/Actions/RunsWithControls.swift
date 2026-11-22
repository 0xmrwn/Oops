import OopsCore
import SwiftUI

/// The model button on Runs with: the glass capsule of Fix's picker, its list opening beside it. With no model to
/// pick from at all it takes the person to Providers instead.
struct RunModelButton: View {
    let store: ProviderStore
    let title: String
    /// The provider whose mark leads the name; none for "Same as Fix".
    let mark: Provider?
    let label: String
    var help: String?
    var enabled = true
    /// No model to pick from, and none to fall back on: the button leads to Providers instead.
    let needsProvider: Bool
    let groups: [(provider: Provider, models: [CatalogModel])]
    let current: ModelSelection.Choice?
    var leading: String?
    var leadingIsCurrent = false
    /// nil is the leading row.
    let choose: (ModelSelection.Choice?) -> Void
    @State private var presented = false

    var body: some View {
        Button {
            if needsProvider { store.wantsProvidersPage = true } else { presented = true }
        } label: {
            HStack(spacing: 6) {
                if let mark { ProviderMark(provider: mark, size: 15) }
                Text(needsProvider ? "Add a provider" : label).fontWeight(.medium)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .contentTransition(.opacity)
        }
        .buttonStyle(.settingsGlass)
        .controlSize(.large)
        .disabled(!enabled)
        .help(help ?? "")
        .accessibilityLabel(title)
        .accessibilityValue(label)
        .onReceive(NotificationCenter.default.publisher(for: .settingsPageWillChange)) { _ in presented = false }
        // Screenshot aid: `-SettingsPreviewActionPage picker` opens the list at launch.
        .task {
            guard DebugFlags.settingsActionPage == "picker" else { return }
            try? await Task.sleep(for: .milliseconds(800))
            presented = true
        }
        // Beside the button, pointing at its chevron: under it, centred on a button at the card's right edge, the list
        // hung out past the window.
        .overlay(alignment: .trailing) {
            Color.clear.frame(width: 22).padding(.trailing, 8).allowsHitTesting(false)
                .popover(isPresented: $presented, arrowEdge: .leading) {
                    RunModelPopover(store: store, groups: groups, current: current, leading: leading, leadingIsCurrent: leadingIsCurrent,
                                    choose: { presented = false; choose($0) }, dismiss: { presented = false })
                }
        }
    }
}

private struct RunModelPopover: View {
    let store: ProviderStore
    let groups: [(provider: Provider, models: [CatalogModel])]
    let current: ModelSelection.Choice?
    let leading: String?
    let leadingIsCurrent: Bool
    let choose: (ModelSelection.Choice?) -> Void
    let dismiss: () -> Void
    @FocusState private var focus: ModelPickerFocus?

    var body: some View {
        ModelList(store: store, groups: groups, current: current, leading: leading, leadingIsCurrent: leadingIsCurrent, maxHeight: 360,
                  choose: choose, dismiss: dismiss, focus: $focus)
            .frame(width: 280)
            .padding(14)
            // The list has the keyboard, not the search field: a caret nobody asked for.
            .onAppear { focus = .list }
    }
}

/// The level of reasoning, for a model that lists levels: its name and the slider Fix's picker has.
struct ReasoningRow: View {
    let model: CatalogModel
    let selection: String
    let select: (String) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        SettingRow(symbol: "brain", title: "Reasoning") {
            HStack(spacing: 12) {
                Text(ModelSelection.effortName(selection)).secondaryText().fixedSize().contentTransition(.opacity)
                EffortSlider(efforts: model.efforts, selection: selection, focused: focused && FocusRings.shared.shown, select: select)
                    .frame(width: 170)
                    .focusable()
                    .focused($focused)
                    .focusEffectDisabled()
                    .onKeyPress(.leftArrow) { step(-1); return .handled }
                    .onKeyPress(.rightArrow) { step(1); return .handled }
            }
        }
    }

    private func step(_ delta: Int) {
        let ids = model.efforts.map(\.id)
        guard let index = ids.firstIndex(of: selection) else { return }
        let next = min(max(index + delta, 0), ids.count - 1)
        if next != index { select(ids[next]) }
    }
}

/// One thing the agent may do: a switch, with an ⓘ beside the title saying what it lets the agent do.
struct AgentSwitchRow: View {
    let symbol: String
    let title: String
    @Binding var isOn: Bool
    let tip: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 18, weight: .medium)).frame(width: 24).secondaryText().accessibilityHidden(true)
            Text(title).fontWeight(.semibold)
            // Above the row: below, the last rows' tips hung past the window's bottom edge.
            InfoTip(title, tip, edge: .top).padding(.leading, -8)
            Spacer(minLength: 8)
            Toggle(title, isOn: $isOn).settingsSwitch().labelsHidden()
        }
        .padding(.vertical, 6)
        .frame(minHeight: 44)
    }
}

/// An agent Oops can run an action through: Claude Code now, Codex when it can.
struct HarnessRow: View {
    let name: String
    let mark: String
    let selected: Bool
    let available: Bool

    var body: some View {
        HStack(spacing: 14) {
            Image(mark, bundle: .main).renderingMode(.template).resizable().interpolation(.high).foregroundStyle(.primary)
                .frame(width: 18, height: 18).frame(width: 24).accessibilityHidden(true)
            Text(name).fontWeight(.semibold)
            Spacer(minLength: 8)
            if available {
                Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold)).opacity(selected ? 1 : 0).accessibilityHidden(true)
            } else {
                Text("Coming soon").secondaryText()
            }
        }
        .padding(.vertical, 6)
        .frame(minHeight: 44)
        .opacity(available ? 1 : 0.55)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
