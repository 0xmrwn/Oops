import OopsCore
import SwiftUI

/// The Provider step over Hello's blurred desktop. The drop that ended Hello stays as its companion
/// (drawn by the window, at `OnboardingDropKey`'s "step" anchor): it scans while detection runs, looks
/// at each row as it lands and turns into a check once the chosen provider has corrected a word.
struct ProviderStepView: View {
    let step: ProviderStep
    let next: () -> Void
    @FocusState private var apiFocus: APIProviderSetupView.Field?
    /// The step's height, which the list's fit is worked out in.
    @State private var room: CGFloat?
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    var reduceMotion: Bool { systemReduceMotion || DebugFlags.brandReduceMotion }
    private var ready: Bool { if case .passed = step.proof { true } else { false } }

    var body: some View {
        // Pinned from the top, so rows landing push what's below them and never move the drop.
        OnboardingStepLayout(height: ProviderListFit.column, trim: fit.trim) { column } primary: { primary } leading: { back } skip: { skip }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { room = $0 }
            .animation(reduceMotion ? nil : .spring(duration: 0.5, bounce: 0.3), value: ready)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: step.showingAPI)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: fit)
            .onAppear {
                step.reduceMotion = reduceMotion
                step.start()
            }
    }

    /// Worked out for every row detection found, not the ones landed so far, so the list settles once
    /// rather than tightening under each row as it lands.
    var fit: ProviderListFit {
        guard let room, !step.showingAPI else { return ProviderListFit() }
        #if DEBUG
        if DebugFlags.onboardingProviderSections { return sectionsFit(in: room) }
        #endif
        let count = step.findings.rows.count
        return ProviderListFit(room: room, viewports: Array((1..<max(count, 1)).reversed())) { fit in
            // The API item below them.
            let items = CGFloat((fit.visible ?? count) + 1)
            return items * ProviderListItem.height + (items - 1) * fit.spacing
        }
    }

    private var column: some View {
        VStack(spacing: 0) {
            Color.clear.frame(width: 84, height: 84)
                .anchorPreference(key: OnboardingDropKey.self, value: .bounds) { ["step": $0] }
            Text(step.showingAPI ? "Connect an API" : "Choose a provider").font(.system(size: 26, weight: .semibold))
                .padding(.top, fit.dropToTitle)
            Group {
                if step.showingAPI {
                    APIProviderSetupView(setup: step.api, focus: $apiFocus)
                } else {
                    VStack(spacing: 0) {
                        Group {
                            #if DEBUG
                            if DebugFlags.onboardingProviderSections { sectionedRows } else { rows }
                            #else
                            rows
                            #endif
                        }
                        .frame(width: ProviderListItem.width)
                        // The room left down to Continue's top edge, so the chip sits midway at any window height.
                        ProofChip(proof: step.proof).frame(maxHeight: .infinity)
                    }
                }
            }
            .padding(.top, fit.titleToList)
        }
        .padding(.bottom, OnboardingFooter.primaryTop)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }

    private var rows: some View {
        GlassEffectContainer(spacing: fit.spacing) {
            VStack(spacing: fit.spacing) {
                if let visible = fit.visible, !step.shown.isEmpty { scrolling(visible) } else { detectedRows }
                apiItem
            }
        }
    }

    private var detectedRows: some View {
        VStack(spacing: fit.spacing) {
            ForEach(step.shown) { item($0).id($0) }
        }
    }

    /// `visible` whole items at a time, coming to rest on an item's edge so none is ever cut; the API item stays
    /// below, in view. The viewport grows as rows land, so it never stands empty under them.
    private func scrolling(_ visible: Int) -> some View {
        let shown = CGFloat(min(visible, step.shown.count))
        return ScrollViewReader { proxy in
            ScrollView {
                GlassEffectContainer(spacing: fit.spacing) { detectedRows.scrollTargetLayout() }
            }
            .scrollTargetBehavior(.viewAligned)
            .frame(height: shown * ProviderListItem.height + (shown - 1) * fit.spacing)
            .providerListScrolls()
            // A preselected row below the fold comes up to the last place in view.
            .onChange(of: step.selected, initial: true) { _, row in
                guard let row, let index = step.shown.firstIndex(of: row), let first = step.shown.first else { return }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) {
                    if index < visible { proxy.scrollTo(first, anchor: .top) } else { proxy.scrollTo(row, anchor: .bottom) }
                }
            }
        }
    }

    /// A ready provider as a glass row. ChatGPT and Claude Code, until they're ready, as their own
    /// branded buttons: the same pair whatever else this Mac has.
    func item(_ row: ProviderFindings.Row) -> some View {
        Group {
            if !needsButton(row) {
                ProviderStepRow(row: row, step: step)
            } else if row == .chatGPT {
                ContinueWithChatGPTButton(loading: step.signingIn, listed: true) { step.signIn(.chatGPT) }
            } else {
                ClaudeCodeButton(need: step.findings.claude == .notInstalled ? .install : .signIn,
                                 loading: step.signingInToClaude) { step.signIn(.claude) }
            }
        }
        .transition(reduceMotion ? .opacity : .asymmetric(insertion: .offset(y: 18).combined(with: .opacity).combined(with: .scale(scale: 0.96)), removal: .opacity))
    }

    var apiItem: some View {
        Button { step.openAPI() } label: {
            ProviderListLabel(title: "API provider") {
                ProviderMark(provider: Provider(id: "onboarding-api", kind: .api(preset: nil), name: "API provider"), size: ProviderListItem.mark)
            } trailing: {
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold))
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .glassEffect(.clear.interactive(), in: .rect(cornerRadius: ProviderListItem.radius))
    }

    private func needsButton(_ row: ProviderFindings.Row) -> Bool {
        (row == .claude || row == .chatGPT) && !step.findings.isUsable(row)
    }

    @ViewBuilder private var primary: some View {
        if step.showingAPI {
            APIProviderSetupPrimary(setup: step.api, focus: $apiFocus) { if step.commitAPI() { step.stop(); next() } }
        } else if ready {
            OnboardingNextButton(title: "Continue") { step.commit(); step.stop(); next() }
                .transition(reduceMotion ? .opacity : .scale(scale: 0.9).combined(with: .opacity))
        }
    }

    /// Back keeps what was typed for another try. Escape is Back too (the window's).
    @ViewBuilder private var back: some View {
        if step.showingAPI {
            Button(action: step.backFromAPI) { Label("Back", systemImage: "chevron.left") }
                .keyboardShortcut("[", modifiers: .command)
                .onboardingSecondaryButton().transition(.opacity)
        }
    }

    @ViewBuilder private var skip: some View {
        if step.showingAPI || !ready {
            OnboardingSkipButton { if step.showingAPI { step.discardAPI() }; step.stop(); next() }.transition(.opacity)
        }
    }
}

/// A provider that can correct, or a local server wanting a key: its mark and name, then how it's doing or Set up.
private struct ProviderStepRow: View {
    let row: ProviderFindings.Row
    let step: ProviderStep

    var body: some View {
        let selected = step.selected == row
        let content = ProviderListLabel(title: name) { mark } trailing: { trailing.font(.system(size: 13, weight: .medium)) }
        Group {
            if step.findings.isUsable(row) {
                Button { step.choose(row) } label: { content.contentShape(.rect) }.buttonStyle(.plain)
            } else {
                content
            }
        }
        // Part of the glass's content: an overlay on the glass never draws inside a GlassEffectContainer.
        .overlay { RoundedRectangle(cornerRadius: ProviderListItem.radius).strokeBorder(.white.opacity(selected ? 0.7 : 0), lineWidth: 1.5) }
        .glassEffect(selected ? .clear.tint(.white.opacity(0.14)).interactive() : .clear.interactive(), in: .rect(cornerRadius: ProviderListItem.radius))
        .animation(.spring(duration: 0.35), value: selected)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var name: String {
        switch row {
        case .claude: "Claude Code"
        case .chatGPT: "ChatGPT"
        case .local(let id): ProviderPreset(id: id)?.name ?? id
        }
    }

    /// The marks the branded buttons draw, so signing in turns a button into its row without the mark moving or resizing.
    @ViewBuilder private var mark: some View {
        switch row {
        case .claude: ClaudeSpark()
        case .chatGPT: ChatGPTMark(size: ProviderListItem.mark)
        case .local(let id): ProviderMark(provider: Provider(id: "onboarding-" + id, kind: .api(preset: id), name: name), size: ProviderListItem.mark)
        }
    }

    @ViewBuilder private var trailing: some View {
        // The drop shows the check: the row only says it's working or that it failed.
        if step.selected == row, step.proof == .running {
            ProgressView().controlSize(.small).tint(.white)
        } else if step.selected == row, case .failed = step.proof {
            Image(systemName: "exclamationmark.circle").font(.system(size: 15, weight: .semibold))
        } else if step.findings.isUsable(row) {
            Text(row == .claude || row == .chatGPT ? "Signed in" : "Running").opacity(0.7)
        } else if case .local(let id) = row {
            Button("Set up") { step.openAPI(preset: ProviderPreset(id: id)) }.buttonStyle(.glass)
        }
    }
}

/// A glass item's content, laid out as the branded buttons are: the mark in the list's column, the name after it,
/// `trailing` against the far edge.
private struct ProviderListLabel<Mark: View, Trailing: View>: View {
    let title: String
    @ViewBuilder let mark: Mark
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: ProviderListItem.gap) {
            mark.frame(width: ProviderListItem.mark, height: ProviderListItem.mark)
            Text(title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, ProviderListItem.inset)
        .frame(width: ProviderListItem.width, height: ProviderListItem.height)
    }
}

/// The proof: the sloppy sample while the provider works, then its answer in place, the words it
/// fixed flashed as the drop flashes them, and how long it took.
struct ProofChip: View {
    let proof: ProviderStep.Proof
    @State private var flash = 0.0

    var body: some View {
        Group {
            switch proof {
            case .idle: Color.clear.frame(width: 1)
            case .running, .passed:
                HStack(spacing: 10) {
                    if let answer {
                        HStack(spacing: 0) {
                            ForEach(Array(Self.words(answer).enumerated()), id: \.offset) { index, word in
                                Text(verbatim: word)
                                    .padding(.horizontal, 2).padding(.vertical, 1)
                                    .background(Color.accentColor.opacity(fixed(index, in: answer) ? 0.4 * flash : 0), in: .rect(cornerRadius: 5))
                            }
                        }
                        .transition(.opacity)
                    } else {
                        Text(verbatim: ProviderStep.sample).opacity(0.75).padding(.horizontal, 2).transition(.opacity)
                    }
                    if case .passed(_, let seconds) = proof {
                        Text(TestEditorModel.seconds(seconds)).font(.system(size: 13, weight: .medium)).monospacedDigit().opacity(0.7)
                    }
                }
                .font(.system(size: 15, weight: .medium))
                .animation(.easeOut(duration: 0.25), value: answer)
                .padding(.horizontal, 14).frame(height: 34)
                .glassEffect(.clear, in: .capsule)
                .accessibilityElement(children: .combine)
            case .failed(let message):
                Text(message).font(.system(size: 13, weight: .medium)).multilineTextAlignment(.center).lineLimit(2)
                    .frame(maxWidth: 440).opacity(0.85)
            }
        }
        .onChange(of: proof) { _, proof in
            guard case .passed = proof else { flash = 0; return }
            flash = 1
            withAnimation(.easeOut(duration: 1.4).delay(0.5)) { flash = 0.25 }
        }
    }

    private var answer: String? { if case .passed(let answer, _) = proof { answer } else { nil } }

    /// Words with the space after them, so the flash hugs each word and the sentence still wraps as one.
    private static func words(_ text: String) -> [String] {
        text.split(separator: " ", omittingEmptySubsequences: false).enumerated().map { $0 == 0 ? String($1) : " " + $1 }
    }

    /// A word the provider changed: compared word by word with the sample when both have as many words.
    private func fixed(_ index: Int, in answer: String) -> Bool {
        let before = ProviderStep.sample.split(separator: " "), after = answer.split(separator: " ")
        guard before.count == after.count, after.indices.contains(index) else { return false }
        return before[index] != after[index]
    }
}

/// Onboarding's forward action: the label centred, the arrow against the trailing edge, clear of
/// it. An action that leaves onboarding (Open System Settings) carries its icon before the label
/// and no arrow.
struct OnboardingNextButton: View {
    let title: String
    var icon: String?
    var symbol: String? = "arrow.right"
    var width: CGFloat = 200
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon { Image(systemName: icon).font(.system(size: 17, weight: .semibold)) }
                Text(title)
            }
            .frame(width: width)
            .overlay(alignment: .trailing) { if let symbol { Image(systemName: symbol).font(.system(size: 16, weight: .bold)) } }
            .font(.system(size: 18, weight: .semibold)).foregroundStyle(.white).padding(.horizontal, 6).padding(.vertical, 6)
        }
        .buttonStyle(.glass).controlSize(.extraLarge)
        .keyboardShortcut(.defaultAction)
    }
}

/// Where the companion drop sits: "finale" in Hello's last pane, "step" atop a setup step.
struct OnboardingDropKey: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] { [:] }
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}
