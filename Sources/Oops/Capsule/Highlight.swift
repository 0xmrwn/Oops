import AppKit
import ApplicationServices

/// The Try page's flash, over another app's draft: a click-through panel laid over the editor,
/// with a glowing pill on each changed word where Accessibility says the editor drew it. Unlike
/// the Try page, the pills sit above the glyphs, not behind them, so the tint stays light.
/// Cleared when the editor's text or selection changes or its window moves, and after the fade.
@MainActor final class HighlightOverlay {
    enum Style { case correction, restore }
    private static let elementNotifications = [kAXValueChangedNotification, kAXSelectedTextChangedNotification]
    private let panel: NSPanel
    private let content = NSView()
    private let tracker = WindowTracker()
    private var generation = 0
    private var observers: [NSObjectProtocol] = []
    private var watch: Task<Void, Never>?

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.title = "Oops Highlights"
        panel.level = .floating; panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
        panel.setAccessibilityElement(false)
        if let appearance = DebugFlags.capsuleAppearance {
            panel.appearance = NSAppearance(named: appearance == "light" ? .aqua : .darkAqua)
        }
        content.wantsLayer = true
        panel.contentView = content
    }

    /// `rects` are in AX coordinates (top-left, global). `element` is the draft they belong to.
    /// `anchor` re-measures the first word while the flash is up: scrolling moves the glyphs with
    /// no text, selection or window notification, so a moved (not a missing) answer clears the pills.
    func flash(_ rects: [CGRect], style: Style, element: AXUIElement, anchor: (() async -> CGRect?)? = nil) {
        clear()
        guard !rects.isEmpty else { return }
        generation += 1
        let generation = generation
        // The pills belong to the draft in front: another app or Space coming forward leaves them over unrelated content.
        let host = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.generation == generation else { return }
                    if NSWorkspace.shared.frontmostApplication?.processIdentifier != host { self.clear() }
                }
            })
        }
        if let anchor, let first = rects.first {
            watch = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard !Task.isCancelled, let self, self.generation == generation else { return }
                    guard let now = await anchor() else { continue }
                    if abs(now.minX - first.minX) > 1 || abs(now.minY - first.minY) > 1 { self.clear(); return }
                }
            }
        }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || EyesDropView.forced.contains("reduce-motion")
        let primary = NSScreen.screens.first?.frame.maxY ?? 900
        // Room for the pills' inset and the spring overshoot.
        let union = rects.dropFirst().reduce(rects[0]) { $0.union($1) }.insetBy(dx: -8, dy: -8)
        panel.setFrame(NSRect(x: union.minX, y: primary - union.maxY, width: union.width, height: union.height), display: false)
        var color = NSColor.clear
        panel.effectiveAppearance.performAsCurrentDrawingAppearance {
            let dark = panel.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            color = style == .correction
                ? NSColor.controlAccentColor.withAlphaComponent(dark ? 0.38 : 0.24)
                : NSColor.labelColor.withAlphaComponent(dark ? 0.18 : 0.1)
        }
        let duration = ResultTiming.flash
        for (index, rect) in rects.prefix(200).enumerated() {
            let local = CGRect(x: rect.minX - union.minX, y: union.maxY - rect.maxY, width: rect.width, height: rect.height)
                .insetBy(dx: rect.width <= 3 ? 0 : -3, dy: -1)
            let pill = NSView(frame: local)
            pill.wantsLayer = true
            let shape = CALayer()
            shape.frame = pill.bounds
            shape.cornerRadius = min(local.height / 2, 6)
            shape.cornerCurve = .continuous
            shape.backgroundColor = color.cgColor
            shape.opacity = 0
            pill.layer?.addSublayer(shape)
            content.addSubview(pill)
            let delay = reduceMotion ? 0 : min(Double(index) * 0.04, 0.32)
            let begin = CACurrentMediaTime() + delay
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0, 1, 1, 0]
            fade.keyTimes = [0, 0.1, 0.5, 1]
            fade.duration = duration
            fade.beginTime = begin
            fade.fillMode = .both
            shape.add(fade, forKey: "fade")
            if !reduceMotion {
                let pop = CASpringAnimation(keyPath: "transform.scale")
                pop.fromValue = 0.82; pop.toValue = 1
                pop.damping = 14; pop.stiffness = 260; pop.mass = 0.8
                pop.duration = pop.settlingDuration
                pop.beginTime = begin
                pop.fillMode = .backwards
                shape.add(pop, forKey: "pop")
            }
        }
        panel.orderFrontRegardless()
        // The pills mark where words were; any edit, scroll or move makes that stale at once. The
        // paste's own value and caret notifications still arrive for a moment: arm after they pass.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, self.generation == generation, self.panel.isVisible else { return }
            self.tracker.track(element, elementNotifications: Self.elementNotifications) { [weak self] in self?.clear() }
        }
        let total = duration + (reduceMotion ? 0 : 0.35) + 0.1
        DispatchQueue.main.asyncAfter(deadline: .now() + total) { [weak self] in
            guard let self, self.generation == generation else { return }
            self.clear()
        }
    }

    func clear() {
        tracker.stop()
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }; observers = []
        watch?.cancel(); watch = nil
        content.subviews.forEach { $0.removeFromSuperview() }
        if panel.isVisible { panel.orderOut(nil) }
    }
}
