import CoreGraphics

public extension CapsulePlacement {
    /// A display, in the same top-left, global points as the rest of the engine.
    struct Screen: Equatable, Sendable {
        /// The area without the menu bar and the Dock.
        public var visible: CGRect
        public var full: CGRect
        /// How far the notch or camera housing reaches down from the top of `full`; 0 without one.
        public var safeAreaTop: CGFloat
        public init(visible: CGRect, full: CGRect, safeAreaTop: CGFloat = 0) {
            self.visible = visible; self.full = full; self.safeAreaTop = safeAreaTop
        }
    }

    /// The envelope for a drop fixed to the top or the bottom of a screen, centred: the one `anchor` (the
    /// focused window) is mostly on, else the first of `screens`. `anchored` has no fixed spot, so it
    /// is placed as the bottom; resolve it first with `DictationDropPosition.resolved(hasAnchor:)`.
    static func fixed(_ position: DictationDropPosition, envelope size: CGSize, screens: [Screen],
                      anchor: CGRect? = nil, margin: CGFloat = 12) -> Placement {
        let chosen = bestScreen(for: anchor, in: screens.map(\.visible))
        let screen = screens.first { $0.visible == chosen } ?? Screen(visible: chosen, full: chosen)
        // The visible frame already starts under the menu bar; the safe area covers a notch taller than it.
        let topEdge = max(screen.visible.minY, screen.full.minY + screen.safeAreaTop)
        let y = position == .top ? topEdge + margin : screen.visible.maxY - margin - size.height
        let rect = CGRect(x: screen.visible.midX - size.width / 2, y: y, width: size.width, height: size.height)
        return Placement(envelope: clamp(rect, into: screen.visible), corner: .bottom, strategy: .screen)
    }
}
