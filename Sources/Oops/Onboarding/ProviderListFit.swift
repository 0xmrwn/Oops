import SwiftUI

/// How the Provider step's list fits between its title and Continue, the proof chip midway with room on
/// either side. No item is ever partly in view: every item shows whole when they fit; when they don't, the
/// column tightens only as much as that list needs, and only past that does the list scroll, showing a
/// whole number of items. A list as short as most Macs give keeps the step's usual look.
struct ProviderListFit: Equatable {
    var dropToTitle: CGFloat = 20
    var titleToList: CGFloat = 26
    var spacing: CGFloat = 10
    /// Off the step's top margin, which moves the drop: the last thing to give.
    var trim: CGFloat = 0
    /// How many detected items show before the rest scroll; nil when they all show. The sections prototype
    /// scrolls a section at a time and only reads whether it's set.
    var visible: Int?

    /// The column `OnboardingStepLayout` centres; the drop's frame and the title's line.
    static let column: CGFloat = 450, drop: CGFloat = 84, title: CGFloat = 31
    /// The proof chip, and the least room kept above and below it.
    static let chip: CGFloat = 34, chipGap: CGFloat = 16

    init() {}

    /// `room` is the step's height; `viewports` the scrolling lists to try, most items first; `list` how tall
    /// the list stands in a fit.
    init(room: CGFloat, viewports: [Int], list: (Self) -> CGFloat) {
        let top = OnboardingFooter.columnTop(in: room, column: Self.column)
        func short(_ fit: Self) -> CGFloat {
            let above = top - fit.trim + Self.drop + fit.dropToTitle + Self.title + fit.titleToList
            return (above + list(fit) + Self.chip + 2 * Self.chipGap - (room - OnboardingFooter.primaryTop)).rounded(.up)
        }
        // Tightest last, from the list up, so the drop stays put for as long as it can.
        var fit = Self()
        if short(fit) > 0 { fit.titleToList -= min(short(fit), 10) }
        if short(fit) > 0 { fit.spacing = 8 }
        if short(fit) > 0 { fit.dropToTitle -= min(short(fit), 8) }
        if short(fit) > 0 { fit.trim = min(short(fit), max(0, top - 16)) }
        guard short(fit) > 0 else { self = fit; return }
        // Still too long: the usual look, scrolling the most items that leave the chip its room.
        for count in viewports {
            var scrolling = Self()
            scrolling.visible = count
            if short(scrolling) <= 0 { self = scrolling; return }
        }
        fit.visible = viewports.last
        self = fit
    }
}

extension View {
    /// A scrolling stretch of the provider list. See `ProviderListScrollEdges`.
    func providerListScrolls() -> some View { modifier(ProviderListScrollEdges()) }
}

/// Reads as a list that scrolls rather than as items cut off: the view rests on whole items, and a thin bar
/// beside the list says there's more and where the view is. No edge fade: at rest it would dim a whole item,
/// which reads as a broken one. The system's overlay scroller hides between scrolls, so it can't say that on
/// its own, and inside the list it would sit over the items' glass.
private struct ProviderListScrollEdges: ViewModifier {
    struct Position: Equatable { var offset: CGFloat = 0, content: CGFloat = 0, viewport: CGFloat = 0 }
    @State private var position = Position()
    private static let bar: CGFloat = 4

    func body(content: Content) -> some View {
        let travel = position.content - position.viewport
        content
            .scrollIndicators(.never)
            .onScrollGeometryChange(for: Position.self) { geometry in
                Position(offset: geometry.contentOffset.y + geometry.contentInsets.top,
                         content: geometry.contentSize.height, viewport: geometry.containerSize.height)
            } action: { position = $1 }
            .overlay(alignment: .topTrailing) {
                bar(travel: travel).offset(x: Self.bar + 8).opacity(travel > 0.5 ? 1 : 0).accessibilityHidden(true)
            }
    }

    private func bar(travel: CGFloat) -> some View {
        let viewport = position.viewport
        let thumb = travel > 0 ? viewport * viewport / position.content : viewport
        let progress = travel > 0 ? min(1, max(0, position.offset / travel)) : 0
        return Capsule().fill(.white.opacity(0.15)).frame(width: Self.bar, height: viewport)
            .overlay(alignment: .top) {
                Capsule().fill(.white.opacity(0.6)).frame(height: thumb).offset(y: progress * (viewport - thumb))
            }
    }
}
