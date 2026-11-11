import SwiftUI

/// The height a short page leaves under it, and where the pointer is. Kept out of `SettingsView`'s
/// state: the pointer changes on every move, and only the eyes read any of it.
@Observable @MainActor final class SpareSpaceModel {
    var content: CGFloat = 0
    var viewport: CGFloat = 0
    /// In window coordinates; nil while the pointer is outside the window.
    var pointer: CGPoint?
    var spare: CGFloat { max(viewport - content, 0) }
    /// The companion's diameter under the page: up to 88 pt, smaller when the room is tight.
    var belowHeight: CGFloat { max(min(88, (spare * 0.55).rounded()), 1) }
    /// Below a legible size (about 30 pt) they leave the page for the header's right side.
    var fitBelow: Bool { belowHeight >= 30 }
}

/// The eyes' other home: the right of the header, smaller, for pages that fill the window.
struct HeaderEyes: View {
    let model: SpareSpaceModel
    /// Pages with eyes of their own (Try's status line) keep the header clear.
    var suppressed = false
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || DebugFlags.brandReduceMotion }

    var body: some View {
        let shown = !model.fitBelow && !suppressed
        WatchingEyes(model: model, height: 34, visible: shown)
            .opacity(shown ? 1 : 0)
            .scaleEffect(shown ? 1 : 0.6, anchor: .trailing)
            .allowsHitTesting(shown)
            .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.4, bounce: 0.2), value: shown)
            .accessibilityHidden(true)
    }
}

/// Settings keeps one window height for every page. A short page leaves room under it, and oops's
/// eyes sit there watching the pointer instead of an empty pane.
struct SpareSpace: View {
    let model: SpareSpaceModel
    var suppressed = false
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || DebugFlags.brandReduceMotion }

    var body: some View {
        let spare = model.spare
        // At full strength whatever their size; too small and they go to the header instead. Always
        // in the tree: inserting and removing them made a switch that briefly narrowed the room
        // flash them.
        let height = model.belowHeight
        let visibility: Double = model.fitBelow && !suppressed ? 1 : 0
        Color.clear
            .frame(height: spare)
            // Only the eyes take clicks (they blink); the empty room around them passes them on.
            .allowsHitTesting(false)
            .overlay {
                WatchingEyes(model: model, height: height, visible: visibility > 0)
                    .opacity(visibility)
                    .scaleEffect(0.9 + 0.1 * visibility)
                    .allowsHitTesting(visibility > 0)
            }
            // A page switch changes the room at once; the eyes move and resize on the page's own
            // spring instead of jumping there.
            .animation(SettingsMotion.page(reduceMotion), value: spare)
            .animation(SettingsMotion.page(reduceMotion), value: suppressed)
            .accessibilityHidden(true)
    }
}

/// The onboarding drop follows the pointer and blinks without changing its glass body.
private struct WatchingEyes: View {
    let model: SpareSpaceModel
    let height: CGFloat
    let visible: Bool
    @State private var center = CGPoint.zero
    @State private var blink = SettingsBlink()
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || DebugFlags.brandReduceMotion }
    @Environment(\.appearsActive) private var active
    private var canBlink: Bool { visible && active && !reduceMotion }

    var body: some View {
        CompanionDrop(look: look, lid: max(Double(blink.lid), model.pointer == nil ? DashEyes.restingLid : 0), ink: .primary.opacity(0.8))
            .frame(width: height, height: height)
            .animation(reduceMotion ? nil : .interactiveSpring(response: 0.3, dampingFraction: 0.78), value: look)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { center = CGPoint(x: $0.midX, y: $0.midY) }
            .contentShape(Rectangle())
            .onTapGesture { Task { await blink.play(times: 1) } }
            .onChange(of: canBlink, initial: true) { _, allowed in blink.setActive(allowed) }
            .onDisappear { blink.setActive(false) }
            .task(id: canBlink) {
                guard canBlink else { return }
                do {
                    while !Task.isCancelled {
                        try await Task.sleep(for: .seconds(Double.random(in: 3...7)))
                        try Task.checkCancellation()
                        // Now and then a double blink, as people do.
                        await blink.play(times: Double.random(in: 0...1) < 0.2 ? 2 : 1)
                    }
                } catch {}
            }
    }

    /// The same bounded gaze as onboarding, in DashEyes' units.
    private var look: CGSize {
        guard let pointer = model.pointer else { return DashEyes.restingLook }
        let dx = pointer.x - center.x, dy = pointer.y - center.y
        let distance = max(hypot(dx, dy), 1)
        let reach = min(distance / 220, 1)
        return CGSize(width: dx / distance * reach, height: dy / distance * reach)
    }
}
