import AppKit
import SwiftUI
import OopsCore

/// The model and how it fixes: the picker and Try, then Customize (the correction rules).
struct ModelCard: View {
    let store: ProviderStore
    let tryIt: () -> Void
    let customize: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Image(systemName: "cpu")
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: 24)
                    .secondaryText()
                    .accessibilityHidden(true)
                Text("Model").fontWeight(.semibold)
                Spacer(minLength: 8)
                ModelPickerButton(store: store) { store.wantsProvidersPage = true }
                Button(action: tryIt) { Label("Try", systemImage: "text.cursor") }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                    .help("Try a correction with this model")
            }
            if let notice = store.notice {
                Label(notice, systemImage: "info.circle").font(.caption).secondaryText()
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider().padding(.top, 4)
            Button(action: customize) {
                HStack(spacing: 14) {
                    Image(systemName: "wand.and.stars").font(.system(size: 17, weight: .medium)).frame(width: 24)
                        .secondaryText().accessibilityHidden(true)
                    Text("Customize").fontWeight(.semibold)
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).secondaryText()
                }
                .padding(.top, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .settingsSurface()
    }
}

private struct ModelPickerButton: View {
    let store: ProviderStore
    let openProviders: () -> Void
    @State private var presented = false
    /// "Providers…" waits for the popover to close: switching pages under a closing popover froze the
    /// old page, then snapped the window to the new height.
    @State private var providersAfterClose = false

    var body: some View {
        let model = store.currentModel, settings = store.currentSettings
        Button {
            if store.pickerGroups.isEmpty { openProviders() } else { presented = true }
        } label: {
            HStack(spacing: 6) {
                if let provider = store.currentProvider, model != nil { ProviderMark(provider: provider, size: 15) }
                Text(model?.name ?? (store.pickerGroups.isEmpty ? "Add a provider" : "Choose a model")).fontWeight(.medium)
                if let effort = settings.effort, model?.efforts.isEmpty == false {
                    Text(ModelSelection.effortName(effort)).foregroundStyle(.secondary)
                }
                if settings.fast, model?.fast != nil {
                    Image(systemName: "bolt.fill").foregroundStyle(.primary).accessibilityLabel("Fast")
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .contentTransition(.opacity)
        }
        .buttonStyle(.glass)
        .controlSize(.large)
        .onReceive(NotificationCenter.default.publisher(for: .settingsPageWillChange)) { _ in presented = false }
        .accessibilityHint("Opens the model and reasoning options")
        // Launch-only screenshot aid: `-SettingsPreviewPopover options|models` opens the popover.
        .task {
            guard DebugFlags.settingsPopover != nil else { return }
            try? await Task.sleep(for: .seconds(1))
            presented = true
        }
        // Anchored to the chevron, at the pill's fixed trailing edge: the pill grows leftwards as the
        // effort label changes, so the popover never slides. Always below: the card sits at the top
        // of General, so there is room, and a pane change can't flip it to the other side.
        .overlay(alignment: .trailing) {
            Color.clear.frame(width: 22).padding(.trailing, 8).allowsHitTesting(false)
                .popover(isPresented: $presented, arrowEdge: .bottom) { popover }
        }
    }

    private var popover: some View {
        ModelPopover(store: store, dismiss: { presented = false }) {
            providersAfterClose = true
            presented = false
        }
        .onDisappear {
            guard providersAfterClose else { return }
            providersAfterClose = false
            openProviders()
        }
    }
}

// MARK: - Popover

private struct ModelPopover: View {
    let store: ProviderStore
    let dismiss: () -> Void
    let openProviders: () -> Void
    @State private var choosing: Bool
    @State private var highlighted: ModelSelection.Choice?
    @FocusState private var focus: Focus?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private enum Focus: Hashable { case slider, list }

    init(store: ProviderStore, dismiss: @escaping () -> Void, openProviders: @escaping () -> Void) {
        self.store = store; self.dismiss = dismiss; self.openProviders = openProviders
        // A model with nothing to adjust opens straight into the list.
        _choosing = State(initialValue: !Self.hasOptions(store.currentModel)
                          || DebugFlags.settingsPopover == "models")
    }

    private static func hasOptions(_ model: CatalogModel?) -> Bool {
        guard let model else { return false }
        return !model.efforts.isEmpty || model.fast != nil
    }

    var body: some View {
        ZStack(alignment: .top) {
            if choosing {
                modelList.transition(PaneSlideTransition(edge: 1, reduceMotion: reduceMotion))
            } else {
                options.transition(PaneSlideTransition(edge: -1, reduceMotion: reduceMotion))
            }
        }
        .frame(width: 300)
        .padding(14)
        .clipped()
        .onAppear {
            highlighted = store.selection.choice
            focus = choosing ? .list : .slider
        }
    }

    private func drill(_ into: Bool) {
        if into { highlighted = store.selection.choice }
        withAnimation(SettingsMotion.drill(reduceMotion)) { choosing = into }
        DispatchQueue.main.async { focus = into ? .list : .slider }
    }

    // MARK: Options pane

    @ViewBuilder private var options: some View {
        if let model = store.currentModel, let provider = store.currentProvider {
            let settings = store.currentSettings
            let effort = model.efforts.first { $0.id == settings.effort }
            let reset = ModelSelection.reset(model)
            VStack(spacing: 12) {
                HStack {
                    fastToggle(model, on: settings.fast).frame(width: 30)
                    Spacer()
                    if let effort {
                        Text(ModelSelection.effortName(effort.id))
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.primary)
                            .contentTransition(.opacity)
                            .accessibilityHidden(true)
                    }
                    Spacer()
                    Button { store.resetChoice() } label: {
                        Image(systemName: "arrow.counterclockwise").frame(width: 16, height: 16)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .disabled(settings == reset)
                    .help(reset.effort.map { "Reset to \(ModelSelection.effortName($0)), standard speed" } ?? "Reset to standard speed")
                    .accessibilityLabel("Reset to defaults")
                    .frame(width: 30)
                }
                Button { drill(true) } label: {
                    HStack(spacing: 8) {
                        ProviderMark(provider: provider, size: 15)
                        Text(model.name).fontWeight(.medium)
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(PopoverRowStyle())
                .accessibilityLabel("Model, \(model.name)")
                .accessibilityHint("Shows the available models")

                if !model.efforts.isEmpty {
                    EffortSlider(efforts: model.efforts, selection: settings.effort ?? "",
                                 focused: focus == .slider) { store.select(effort: $0) }
                        .focusable()
                        .focused($focus, equals: .slider)
                        .focusEffectDisabled()
                        .onKeyPress(.leftArrow) { step(-1, in: model); return .handled }
                        .onKeyPress(.rightArrow) { step(1, in: model); return .handled }
                        .padding(.horizontal, 4)
                    Text(effort?.description ?? " ")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2, reservesSpace: true)
                        .frame(maxWidth: .infinity)
                        .contentTransition(.opacity)
                }
            }
            .onKeyPress(.return) { dismiss(); return .handled }
            .animation(.smooth(duration: 0.2), value: settings)
        }
    }

    @ViewBuilder private func fastToggle(_ model: CatalogModel, on: Bool) -> some View {
        if let tier = model.fast {
            let button = Button { store.setFast(!on) } label: {
                Image(systemName: on ? "bolt.fill" : "bolt").frame(width: 16, height: 16)
            }
            .buttonBorderShape(.circle)
            .help(tier.description.isEmpty ? tier.name : "\(tier.name) · \(tier.description)")
            .accessibilityLabel(tier.name)
            .accessibilityValue(on ? "On" : "Off")
            .accessibilityAddTraits(on ? .isSelected : [])
            // On: the filled bolt on a brighter glass, not the accent colour.
            button.buttonStyle(.glass).foregroundStyle(.primary.opacity(on ? 1 : 0.7))
                .background(Circle().fill(.primary.opacity(on ? 0.16 : 0)))
        } else {
            Color.clear.frame(width: 28, height: 28)
        }
    }

    private func step(_ delta: Int, in model: CatalogModel) {
        let ids = model.efforts.map(\.id)
        guard let index = ids.firstIndex(of: store.currentSettings.effort ?? "") else { return }
        let next = min(max(index + delta, 0), ids.count - 1)
        if next != index { store.select(effort: ids[next]) }
    }

    // MARK: Model list pane

    /// Every shown model in picker order, for arrow-key movement across providers.
    private var choices: [ModelSelection.Choice] {
        store.pickerGroups.flatMap { group in
            store.problem(group.provider.id) == nil ? group.models.map { .init(providerID: group.provider.id, modelID: $0.id) } : []
        }
    }

    private var modelList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if Self.hasOptions(store.currentModel) {
                    Button { drill(false) } label: { Image(systemName: "chevron.left").frame(width: 16, height: 16) }
                        .buttonStyle(.glass)
                        .buttonBorderShape(.circle)
                        .accessibilityLabel("Back")
                        .frame(width: 30)
                } else {
                    Color.clear.frame(width: 30, height: 1)
                }
                Spacer()
                Text("Select model").font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                Color.clear.frame(width: 30, height: 1)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(store.pickerGroups.enumerated()), id: \.element.provider.id) { index, group in
                        let problem = store.problem(group.provider.id)
                        if index > 0 { Divider().padding(.vertical, 6) }
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
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            // Scrolling is the exception (many providers); then the bar shows, so nothing hides below.
            .scrollIndicators(.visible)
            .frame(maxHeight: 560)
            .fixedSize(horizontal: false, vertical: true)
            .focusable()
            .focused($focus, equals: .list)
            .focusEffectDisabled()
            .onKeyPress(.upArrow) { moveHighlight(-1); return .handled }
            .onKeyPress(.downArrow) { moveHighlight(1); return .handled }
            .onKeyPress(.return) {
                if let highlighted, choices.contains(highlighted) { choose(highlighted) }
                return .handled
            }
            .onKeyPress(.leftArrow) { if Self.hasOptions(store.currentModel) { drill(false) }; return .handled }
            Divider()
            Button(action: openProviders) {
                HStack {
                    Text("Providers…")
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(PopoverRowStyle())
        }
        .onKeyPress(.escape) {
            if Self.hasOptions(store.currentModel) { drill(false) } else { dismiss() }
            return .handled
        }
    }

    private func row(_ model: CatalogModel, in provider: Provider, disabled: Bool) -> some View {
        let choice = ModelSelection.Choice(providerID: provider.id, modelID: model.id)
        let current = choice == store.selection.choice
        return Button { choose(choice) } label: {
            HStack(spacing: 8) {
                // Indented to the provider name above it: the header is the group, rows its members.
                Text(model.name).padding(.leading, 26)
                Spacer(minLength: 4)
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .opacity(current ? 1 : 0)
            }
        }
        .buttonStyle(PopoverRowStyle(highlighted: highlighted == choice))
        .disabled(disabled)
        .onHover { if $0, !disabled { highlighted = choice } }
        .accessibilityLabel("\(model.name), \(provider.name)")
        .accessibilityAddTraits(current ? .isSelected : [])
    }

    private func moveHighlight(_ delta: Int) {
        let list = choices
        guard !list.isEmpty else { return }
        let index = highlighted.flatMap { list.firstIndex(of: $0) } ?? 0
        highlighted = list[min(max(index + delta, 0), list.count - 1)]
    }

    private func choose(_ choice: ModelSelection.Choice) {
        store.select(choice)
        if Self.hasOptions(store.currentModel) { drill(false) } else { dismiss() }
    }
}

struct PopoverRowStyle: ButtonStyle {
    var highlighted = false
    func makeBody(configuration: Configuration) -> some View { Styled(configuration: configuration, highlighted: highlighted) }
    private struct Styled: View {
        let configuration: Configuration
        let highlighted: Bool
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled
        var body: some View {
            configuration.label
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.primary.opacity(configuration.isPressed ? 0.14 : (hovering || highlighted) && isEnabled ? 0.08 : 0),
                            in: .rect(cornerRadius: 9))
                .opacity(isEnabled ? 1 : 0.45)
                .contentShape(.rect(cornerRadius: 9))
                .onHover { hovering = $0 }
        }
    }
}

/// Dotted step slider: one dot per supported effort, a white knob and a monochrome filled track up
/// to it, thicker than the empty part so the level reads at a glance.
/// Click or drag to choose; the parent handles arrow keys while it is focused.
struct EffortSlider: View {
    let efforts: [CatalogModel.Effort]
    let selection: String
    let focused: Bool
    let select: (String) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    private let knob: CGFloat = 18
    /// How far track and fill extend past the end stops.
    private static let overhang: CGFloat = 6

    var body: some View {
        let index = efforts.firstIndex { $0.id == selection } ?? 0
        GeometryReader { geometry in
            let width = geometry.size.width - knob
            let x = { (i: Int) -> CGFloat in
                knob / 2 + (efforts.count > 1 ? width * CGFloat(i) / CGFloat(efforts.count - 1) : width / 2)
            }
            let mid = geometry.size.height / 2
            ZStack(alignment: .topLeading) {
                // Track and fill run a little past the first and last stops, so the end dots sit
                // inside the rounded caps; both start at the same point, the fill thicker.
                let start = x(0) - Self.overhang, end = x(efforts.count - 1) + Self.overhang
                Capsule().fill(.primary.opacity(0.14))
                    .frame(width: end - start, height: 5)
                    .position(x: (start + end) / 2, y: mid)
                Capsule().fill(.primary.opacity(0.7))
                    .frame(width: x(index) - start, height: 7)
                    .position(x: start + (x(index) - start) / 2, y: mid)
                ForEach(efforts.indices, id: \.self) { i in
                    // On the filled part the dots take the opposite tone, so they stay visible.
                    Circle()
                        .fill(i <= index ? (colorScheme == .dark ? Color.black.opacity(0.45) : Color.white.opacity(0.9))
                                         : Color.primary.opacity(0.4))
                        .frame(width: 4, height: 4)
                        .position(x: x(i), y: mid)
                }
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.28), radius: 2, y: 1)
                    // A firmer edge: in dark mode the knob sits on a near-white fill.
                    .overlay(Circle().strokeBorder(.black.opacity(0.2)))
                    .frame(width: knob, height: knob)
                    .overlay {
                        if focused {
                            Circle().strokeBorder(.primary.opacity(0.45), lineWidth: 3).padding(-4)
                        }
                    }
                    .position(x: x(index), y: mid)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                guard efforts.count > 1 else { return }
                let raw = (value.location.x - knob / 2) / max(width, 1) * CGFloat(efforts.count - 1)
                let nearest = min(max(Int(raw.rounded()), 0), efforts.count - 1)
                if efforts[nearest].id != selection { select(efforts[nearest].id) }
            })
            .animation(reduceMotion ? nil : .spring(duration: 0.25, bounce: 0.15), value: index)
        }
        .frame(height: 26)
        .help(efforts.indices.contains(index) ? efforts[index].description : "")
        .accessibilityElement()
        .accessibilityLabel("Reasoning effort")
        .accessibilityValue(ModelSelection.effortName(selection))
        .accessibilityAdjustableAction { direction in
            let next = direction == .increment ? index + 1 : index - 1
            if efforts.indices.contains(next) { select(efforts[next].id) }
        }
    }
}
