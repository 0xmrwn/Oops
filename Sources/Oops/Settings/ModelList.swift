import OopsCore
import SwiftUI

/// Which part of a model picker has the keyboard.
enum ModelPickerFocus: Hashable { case slider, list }

/// The model picker's list: a search field over the providers' groups that narrows them by model or provider name,
/// then the models, keyboard-navigable. Fix's picker and an action's Runs with share it. Opening, searching and
/// closing choose nothing; only a click or Return does.
struct ModelList: View {
    enum Item: Hashable { case leading, model(ModelSelection.Choice) }
    let store: ProviderStore
    let groups: [(provider: Provider, models: [CatalogModel])]
    let current: ModelSelection.Choice?
    /// A row above the groups (an action's "Same as Fix"), checked when `leadingIsCurrent`.
    var leading: String?
    var leadingIsCurrent = false
    /// A header with this title; a back button in it when `back` is set (Fix's options pane).
    var title: String?
    var back: (() -> Void)?
    var openProviders: (() -> Void)?
    var maxHeight: CGFloat = 560
    /// nil is the leading row.
    let choose: (ModelSelection.Choice?) -> Void
    let dismiss: () -> Void
    var focus: FocusState<ModelPickerFocus?>.Binding
    @State private var search = DebugFlags.modelSearch ?? ""
    @State private var highlighted: Item?
    /// Set by the keyboard only, so a hover never scrolls the list under the pointer.
    @State private var scrollTo: Item?

    private var shownGroups: [(provider: Provider, models: [CatalogModel])] {
        ModelSearch.filter(groups, query: search) { $0.name }
    }

    private var leadingShown: Bool { leading.map { ModelSearch.matches(search, $0) } ?? false }

    /// What the arrow keys move through, in order: the leading row, then every model whose provider works.
    private var items: [Item] {
        (leadingShown ? [.leading] : [])
            + shownGroups.flatMap { group in
                store.problem(group.provider.id) == nil ? group.models.map { .model(.init(providerID: group.provider.id, modelID: $0.id)) } : []
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if title != nil { header }
            GlassSearchField(title: "Search", text: $search, onSubmit: chooseHighlighted)
                .onKeyPress(.upArrow) { moveHighlight(-1); return .handled }
                .onKeyPress(.downArrow) { moveHighlight(1); return .handled }
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if let leading, leadingShown { leadingRow(leading).id(Item.leading) }
                    ForEach(Array(shownGroups.enumerated()), id: \.element.provider.id) { index, group in
                        let problem = store.problem(group.provider.id)
                        if index > 0 || leadingShown { SettingsDivider().padding(.vertical, 6) }
                        HStack(spacing: 8) {
                            ProviderMark(provider: group.provider, size: 18)
                            Text(group.provider.name).fontWeight(.semibold)
                            Spacer()
                            if let problem { StatusBadge(problem, ok: false) }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .accessibilityAddTraits(.isHeader)
                        ForEach(group.models) { model in row(model, in: group.provider, disabled: problem != nil) }
                    }
                    if !leadingShown, shownGroups.isEmpty {
                        Text("No model").secondaryText().frame(maxWidth: .infinity).padding(.vertical, 12)
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            // Scrolling is the exception (many providers); then the bar shows, so nothing hides below.
            .scrollIndicators(.visible)
            .frame(maxHeight: maxHeight)
            .fixedSize(horizontal: false, vertical: true)
            .focusable()
            .focused(focus, equals: .list)
            .focusEffectDisabled()
            .onKeyPress(.upArrow) { moveHighlight(-1); return .handled }
            .onKeyPress(.downArrow) { moveHighlight(1); return .handled }
            .onKeyPress(.return) { chooseHighlighted(); return .handled }
            .onKeyPress(.leftArrow) { if let back { back() }; return .handled }
            .onChange(of: scrollTo) { if let scrollTo { proxy.scrollTo(scrollTo) } }
            }
            if let openProviders {
                Button(action: openProviders) {
                    HStack {
                        Text("Providers…")
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(PopoverRowStyle())
            }
        }
        .onKeyPress(.escape) { (back ?? dismiss)(); return .handled }
        .onAppear { highlighted = leadingIsCurrent ? .leading : current.map(Item.model) }
        .onChange(of: search) { highlighted = ModelSearch.highlight(highlighted, in: items) }
    }

    private var header: some View {
        HStack {
            if let back {
                Button(action: back) { Image(systemName: "chevron.left").frame(width: 16, height: 16) }
                    .buttonStyle(.settingsGlass)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel("Back")
                    .frame(width: 30)
            } else {
                Color.clear.frame(width: 30, height: 1)
            }
            Spacer()
            Text(title ?? "").font(.headline).accessibilityAddTraits(.isHeader)
            Spacer()
            Color.clear.frame(width: 30, height: 1)
        }
    }

    private func leadingRow(_ text: String) -> some View {
        Button { choose(nil) } label: {
            HStack(spacing: 8) {
                Text(text)
                Spacer(minLength: 4)
                check(leadingIsCurrent)
            }
        }
        .buttonStyle(PopoverRowStyle(highlighted: highlighted == .leading))
        .onHover { if $0 { highlighted = .leading } }
        .accessibilityLabel(text)
        .accessibilityAddTraits(leadingIsCurrent ? .isSelected : [])
    }

    private func row(_ model: CatalogModel, in provider: Provider, disabled: Bool) -> some View {
        let choice = ModelSelection.Choice(providerID: provider.id, modelID: model.id)
        let isCurrent = choice == current && !leadingIsCurrent
        return Button { choose(choice) } label: {
            HStack(spacing: 8) {
                // Indented to the provider name above it: the header is the group, rows its members.
                Text(model.name).padding(.leading, 26)
                Spacer(minLength: 4)
                check(isCurrent)
            }
        }
        .id(Item.model(choice))
        .buttonStyle(PopoverRowStyle(highlighted: highlighted == .model(choice)))
        .disabled(disabled)
        .onHover { if $0, !disabled { highlighted = .model(choice) } }
        .accessibilityLabel("\(model.name), \(provider.name)")
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    private func check(_ shown: Bool) -> some View {
        Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(.primary).opacity(shown ? 1 : 0)
    }

    private func moveHighlight(_ delta: Int) {
        let list = items
        guard !list.isEmpty else { return }
        let index = highlighted.flatMap { list.firstIndex(of: $0) } ?? (delta > 0 ? -1 : list.count)
        highlighted = list[min(max(index + delta, 0), list.count - 1)]
        scrollTo = highlighted
    }

    private func chooseHighlighted() {
        guard let target = ModelSearch.highlight(highlighted, in: items) else { return }
        switch target {
        case .leading: choose(nil)
        case .model(let choice): choose(choice)
        }
    }
}
