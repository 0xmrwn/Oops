#if DEBUG
import OopsCore
import SwiftUI

/// A prototype behind `-OnboardingProviderSections YES`: the list grouped by how each provider connects, as
/// Zed (External Agents, LLM Providers) and Raycast (Bring Your Own Key, Local Models, Custom Providers) group
/// theirs. By kind rather than by state: ChatGPT stays above Claude Code whichever one is signed in, and
/// signing in never moves an item to another group. The items already show their state.
extension ProviderStepView {
    enum ListSection {
        case accounts, thisMac, own

        var title: String {
            switch self {
            case .accounts: "Accounts"
            case .thisMac: "On this Mac"
            case .own: "Add your own"
            }
        }
    }

    /// The section label's line, and the gap under it.
    private static let labelHeight: CGFloat = 15, labelGap: CGFloat = 6

    /// A labelled section of `items`.
    private static func height(_ items: Int, spacing: CGFloat) -> CGFloat {
        labelHeight + labelGap + CGFloat(items) * ProviderListItem.height + CGFloat(max(items - 1, 0)) * spacing
    }

    /// The accounts and the servers detection found, so the list settles once rather than as rows land.
    private var found: (accounts: Int, servers: Int) {
        let rows = step.findings.rows, accounts = rows.count { $0 == .chatGPT || $0 == .claude }
        return (accounts, rows.count - accounts)
    }

    /// When the sections don't fit whole, the accounts and the servers scroll a section at a time.
    func sectionsFit(in room: CGFloat) -> ProviderListFit {
        let (accounts, servers) = found
        return ProviderListFit(room: room, viewports: servers > 0 ? [1] : []) { fit in
            let own = Self.height(1, spacing: fit.spacing), gap = fit.spacing + 2
            let mine = Self.height(accounts, spacing: fit.spacing), local = Self.height(servers, spacing: fit.spacing)
            if servers == 0 { return mine + gap + own }
            return (fit.visible == nil ? mine + gap + local : max(mine, local)) + gap + own
        }
    }

    var sectionedRows: some View {
        let accounts = step.shown.filter { $0 == .chatGPT || $0 == .claude }
        let servers = step.shown.filter { !accounts.contains($0) }
        // The API item is always there: a label only says something once another group sits beside it.
        let labelled = !step.shown.isEmpty
        return GlassEffectContainer(spacing: fit.spacing) {
            VStack(spacing: fit.spacing + 2) {
                if fit.visible != nil, !servers.isEmpty {
                    scrolledSections(accounts: accounts, servers: servers, labelled: labelled)
                } else {
                    section(.accounts, labelled: labelled) { ForEach(accounts) { item($0) } }
                    if !servers.isEmpty { section(.thisMac, labelled: labelled) { ForEach(servers) { item($0) } } }
                }
                section(.own, labelled: labelled) { apiItem }
            }
        }
    }

    /// One whole section in view at a time, each coming to rest at the top, so no label or item is ever cut.
    private func scrolledSections(accounts: [ProviderFindings.Row], servers: [ProviderFindings.Row], labelled: Bool) -> some View {
        let last = Self.height(found.servers, spacing: fit.spacing)
        let page = max(Self.height(found.accounts, spacing: fit.spacing), last)
        return ScrollViewReader { proxy in
            ScrollView {
                GlassEffectContainer(spacing: fit.spacing) {
                    VStack(spacing: fit.spacing + 2) {
                        section(.accounts, labelled: labelled) { ForEach(accounts) { item($0).id($0) } }.id(ListSection.accounts)
                        section(.thisMac, labelled: labelled) { ForEach(servers) { item($0).id($0) } }.id(ListSection.thisMac)
                    }
                    .scrollTargetLayout()
                    // Room under a shorter last section, so it too can rest at the top.
                    .padding(.bottom, page - last)
                }
            }
            .scrollTargetBehavior(.viewAligned)
            .frame(height: page)
            .providerListScrolls()
            // A preselected server sits below the fold: its section's top comes into view, label first.
            .onChange(of: step.selected, initial: true) { _, row in
                guard let row else { return }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) {
                    if accounts.contains(row) { proxy.scrollTo(ListSection.accounts, anchor: .top) }
                    else if row == servers.first { proxy.scrollTo(ListSection.thisMac, anchor: .top) }
                    else { proxy.scrollTo(row, anchor: .bottom) }
                }
            }
        }
    }

    private func section(_ kind: ListSection, labelled: Bool, @ViewBuilder items: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Self.labelGap) {
            if labelled {
                // In the marks' column, under the items' own type, so it reads as a caption and not a row.
                Text(kind.title).font(.system(size: 12, weight: .semibold)).opacity(0.7)
                    .frame(height: Self.labelHeight).padding(.leading, ProviderListItem.inset)
                    .accessibilityAddTraits(.isHeader)
                    .transition(.opacity)
            }
            VStack(spacing: fit.spacing) { items() }
        }
    }
}
#endif
