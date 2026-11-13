import AppKit
import SwiftUI

/// A feature that shows itself in the drop.
struct DropFeature: Hashable, Sendable {
    let name: String
    static let fix = DropFeature(name: "fix")
    static let dictate = DropFeature(name: "dictate")
}

/// The drop and the flash over the draft, which one feature holds at a time. A feature claims them
/// with the view it shows in the drop, and holds them while it is at work or its drop is up; a claim
/// by another feature meanwhile is refused, and nothing of the holder's changes.
@MainActor final class DropOwner {
    let panel = CapsulePanel()
    let highlight = HighlightOverlay()
    private var claimed: (feature: DropFeature, busy: () -> Bool)?
    /// Whose view the panel holds: kept between claims, so a feature claiming again finds its view as it left it.
    private var shown: DropFeature?

    init() {
        // The flash never outlives the drop it belongs to.
        panel.onHide = { [weak self] in self?.highlight.clear() }
    }

    /// The feature holding the drop: the last to claim it, while it is at work or its drop is up.
    var holder: DropFeature? {
        guard let claimed, panel.isShown || claimed.busy() else { return nil }
        return claimed.feature
    }

    /// Gives the drop to `feature`, with `content` in the panel unless its view is already there, in a panel of
    /// `size`. False while another feature holds it: the caller shows nothing. `busy` says whether the
    /// feature is still at work, which holds the drop while it has yet to show.
    func claim(_ feature: DropFeature, busy: @escaping () -> Bool, size: CGSize = CapsulePanel.standard, content: () -> AnyView) -> Bool {
        if let holder, holder != feature { return false }
        panel.resize(size)
        if shown != feature {
            highlight.clear()
            panel.setContent(content())
            shown = feature
        }
        claimed = (feature, busy)
        return true
    }
}
