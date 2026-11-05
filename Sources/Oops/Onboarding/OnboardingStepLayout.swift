import SwiftUI

/// Where every setup step's controls sit, so they never move from step to step or as a step's content
/// grows: the forward action in one slot just above the dots, Skip at the dots' trailing end and a way
/// back at their leading end. The window draws the dots on the same row.
enum OnboardingFooter {
    /// The dots' row, from the window's bottom edge to its centre.
    static let rowCenter: CGFloat = 32
    static let rowHeight: CGFloat = 36
    static let margin: CGFloat = 28
    /// The forward action's slot: its bottom edge from the window's, and its height.
    static let primaryBottom: CGFloat = 58
    static let primaryHeight: CGFloat = 60
    /// The forward action's own top edge from the window's: an extra-large glass button is 52 tall, centred in its slot.
    static let primaryTop: CGFloat = primaryBottom + (primaryHeight + 52) / 2
    /// What the content column keeps clear of at the bottom.
    static let reserved: CGFloat = primaryBottom + primaryHeight + 12

    /// A step column's top margin in a step `height` tall: centred above the footer when there's room, never under 24.
    static func columnTop(in height: CGFloat, column: CGFloat) -> CGFloat { max(24, (height - reserved - column) / 2) }
}

extension View {
    /// On the dots' row, against `edge` (or centred), centred on the dots vertically.
    func onboardingFooterRow(_ edge: HorizontalAlignment) -> some View {
        frame(height: OnboardingFooter.rowHeight)
            .frame(maxWidth: .infinity, alignment: Alignment(horizontal: edge, vertical: .center))
            .padding(.horizontal, OnboardingFooter.margin)
            .frame(maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, OnboardingFooter.rowCenter - OnboardingFooter.rowHeight / 2)
    }

    /// Skip and Back: small glass capsules, so they read as buttons beside the forward action.
    func onboardingSecondaryButton() -> some View {
        buttonStyle(.glass).font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
    }
}

/// Skip, at the dots' trailing end on every step. Its double chevron points away from Back's single
/// one at the other end: past this step rather than on to the next thing in it, and mirrored for
/// right-to-left like Back's.
struct OnboardingSkipButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text("Skip")
                Image(systemName: "chevron.forward.2").font(.system(size: 10, weight: .semibold)).accessibilityHidden(true)
            }
        }
        .onboardingSecondaryButton()
    }
}

/// A setup step: its column pinned from the top in the room above the footer, its controls in the
/// footer's fixed places. `height` is about how tall the column is, to centre it when there's room; `trim` comes
/// off that top margin when the column needs it (the Provider step's longest list in a small window).
struct OnboardingStepLayout<Content: View, Primary: View, Leading: View, Skip: View>: View {
    let height: CGFloat
    let trim: CGFloat
    let content: Content
    let primary: Primary
    let leading: Leading
    let skip: Skip

    init(height: CGFloat, trim: CGFloat = 0, @ViewBuilder content: () -> Content, @ViewBuilder primary: () -> Primary,
         @ViewBuilder leading: () -> Leading = { EmptyView() }, @ViewBuilder skip: () -> Skip = { EmptyView() }) {
        self.height = height; self.trim = trim
        self.content = content(); self.primary = primary(); self.leading = leading(); self.skip = skip()
    }

    var body: some View {
        ZStack {
            GeometryReader { proxy in
                content.frame(maxWidth: .infinity)
                    .padding(.top, OnboardingFooter.columnTop(in: proxy.size.height, column: height) - trim)
            }
            Group {
                primary
                    .frame(height: OnboardingFooter.primaryHeight)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, OnboardingFooter.primaryBottom)
                leading.onboardingFooterRow(.leading)
                skip.onboardingFooterRow(.trailing)
            }
            .foregroundStyle(.white)
            .environment(\.colorScheme, .dark)
        }
    }
}
