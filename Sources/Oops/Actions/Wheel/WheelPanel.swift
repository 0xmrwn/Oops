import AppKit
import Observation
import OopsCore
import SwiftUI

/// What the wheel's view draws this frame: the controller hands it the stepped motion on every tick.
@MainActor @Observable final class WheelFrame {
    var motion = WheelMotion()
    var ink = WheelInk(page: nil, systemDark: false, increaseContrast: false, reduceTransparency: false)
    /// Reduce Transparency and Increase Contrast apart, for what each takes away as Fix's drop does.
    var reduceTransparency = false
    var increaseContrast = false
    /// Each title's drawn width, measured once per opening, so a name is cut at the limit and never while it is
    /// being revealed.
    var widths: [String: Double] = [:]
    /// The centre takes typing in the app in front: the cue shows, and the hint says what to type.
    var canType = false
    var hintText = ""
    /// VoiceOver's way to a petal: its button chooses it as a click would.
    @ObservationIgnored var choose: @MainActor (ActionPlace) -> Void = { _ in }
}

private final class NeverKeyPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The wheel's own window: never key, never activating, and transparent to the mouse, so the app in front keeps its
/// focus and every key and click reaches the wheel through its tap (`WheelKeys`). A canvas centred on the hub.
@MainActor final class WheelPanel {
    let window: NSPanel
    /// The canvas's top-left corner in screen points (top-left origin), where the tap's pointer positions are.
    private(set) var axOrigin = CGPoint.zero

    init(frame: WheelFrame) {
        window = NeverKeyPanel(contentRect: CGRect(origin: .zero, size: WheelLayout.canvas),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = false
        window.title = "Oops Actions"
        window.level = .floating; window.hidesOnDeactivate = false; window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        window.ignoresMouseEvents = true
        // Debug-only, for design recordings: force the appearance, as the drop does.
        if let appearance = DebugFlags.capsuleAppearance {
            window.appearance = NSAppearance(named: appearance == "light" ? .aqua : .darkAqua)
        }
        let host = NSHostingView(rootView: WheelView(frame: frame))
        // The canvas is fixed: the window never follows the view's ideal size.
        host.sizingOptions = []
        window.contentView = host
    }

    /// Every screen's visible area in screen points with a top-left origin, as placement works.
    static var screens: [CGRect] {
        let primary = NSScreen.screens.first?.frame.maxY ?? 900
        return NSScreen.screens.map { CGRect(x: $0.visibleFrame.minX, y: primary - $0.visibleFrame.maxY,
                                             width: $0.visibleFrame.width, height: $0.visibleFrame.height) }
    }

    /// Puts the canvas's hub at `hub`, in screen points with a top-left origin.
    func place(hub: CGPoint) {
        let primary = NSScreen.screens.first?.frame.maxY ?? 900
        let rect = CGRect(origin: CGPoint(x: hub.x - WheelLayout.hub.x, y: hub.y - WheelLayout.hub.y), size: WheelLayout.canvas)
        axOrigin = rect.origin
        window.setFrame(NSRect(x: rect.minX, y: primary - rect.maxY, width: rect.width, height: rect.height), display: false)
    }

    /// A screen point as a point on the canvas.
    func canvasPoint(_ screen: CGPoint) -> CGPoint { CGPoint(x: screen.x - axOrigin.x, y: screen.y - axOrigin.y) }
}
