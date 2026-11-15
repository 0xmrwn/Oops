import AppKit
import ApplicationServices
import OopsCore

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
    /// The live words' line and the clip it slides in, while a dictation shows them at the caret.
    private var words: (clip: CALayer, text: CATextLayer, fade: CAGradientLayer)?

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
        words?.clip.removeFromSuperlayer(); words = nil
        tracker.stop()
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }; observers = []
        watch?.cancel(); watch = nil
        content.subviews.forEach { $0.removeFromSuperview() }
        if panel.isVisible { panel.orderOut(nil) }
    }

    /// A dictation's words so far as ghost text: one line from the caret (AX points) for at most `width`, in the
    /// field's own font and colour, fainter, with nothing behind it. A line too long for the room keeps its newest
    /// words at the far edge and lets the oldest fade out at the caret. Updated in place: the words change as fast
    /// as speech. They belong to the app in front, so another app or Space coming forward takes them away.
    func showWords(_ live: LiveWords, at caret: CGRect, width: CGFloat, style: CaretStyle) {
        if words == nil {
            clear()
            let host = NSWorkspace.shared.frontmostApplication?.processIdentifier, center = NSWorkspace.shared.notificationCenter
            for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
                observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        if NSWorkspace.shared.frontmostApplication?.processIdentifier != host { self?.clearWords() }
                    }
                })
            }
            let clip = CALayer(), text = CATextLayer(), fade = CAGradientLayer()
            clip.masksToBounds = true
            text.isWrapped = false
            // Across the clip: clear at the caret, solid a little way in.
            fade.startPoint = CGPoint(x: 0, y: 0.5); fade.endPoint = CGPoint(x: 1, y: 0.5)
            fade.colors = [NSColor.clear.cgColor, NSColor.black.cgColor]; fade.locations = [0, 0.07]
            clip.addSublayer(text); content.layer?.addSublayer(clip)
            words = (clip, text, fade)
        }
        guard let (clip, text, fade) = words else { return }
        let size = style.fontSize.map { CGFloat($0) } ?? min(max(caret.height * 0.78, 11), 28)
        let font = style.fontName.map { EditorAccess.font(name: $0, size: size) } ?? NSFont.systemFont(ofSize: size)
        // A field that keeps its colour to itself (AppKit's do) is taken to draw text as the appearance does.
        var base = style.color.map { NSColor(srgbRed: $0.x, green: $0.y, blue: $0.z, alpha: 1) } ?? .textColor
        if style.color == nil {
            panel.effectiveAppearance.performAsCurrentDrawingAppearance { base = NSColor.textColor.usingColorSpace(.sRGB) ?? .gray }
        }
        // Whitespace joined as the drop joins it; only the newest part of a long dictation can show.
        let settled = LiveWords(stable: live.stable).text, all = live.text
        let changing = String(all.dropFirst(settled.count)), stable = (style.spaced ? " " : "") + String(settled.suffix(Self.wordsLimit))
        // Core Text's own colour key: a text layer draws through it and ignores AppKit's.
        let color = NSAttributedString.Key(kCTForegroundColorAttributeName as String)
        let line = NSMutableAttributedString(string: stable, attributes: [.font: font, color: base.withAlphaComponent(0.55).cgColor])
        line.append(NSAttributedString(string: changing, attributes: [.font: font, color: base.withAlphaComponent(0.3).cgColor]))
        let measured = line.size(), height = max(caret.height, ceil(measured.height)), length = ceil(measured.width) + 2
        let frame = CGRect(x: caret.maxX + 1, y: caret.midY - height / 2, width: width, height: height)
        let primary = NSScreen.screens.first?.frame.maxY ?? 900
        CATransaction.begin(); CATransaction.setDisableActions(true)
        panel.setFrame(NSRect(x: frame.minX, y: primary - frame.maxY, width: frame.width, height: frame.height), display: false)
        clip.frame = CGRect(origin: .zero, size: frame.size)
        let over = length > width
        fade.frame = clip.bounds
        clip.mask = over ? fade : nil
        text.frame = CGRect(x: over ? width - length : 0, y: (height - ceil(measured.height)) / 2, width: length, height: ceil(measured.height))
        text.contentsScale = panel.screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        text.string = line
        CATransaction.commit()
        panel.orderFrontRegardless()
    }

    /// More settled text than any line holds.
    private static let wordsLimit = 400

    /// Takes the live words away, and nothing else: a flash never shows beside them.
    func clearWords() {
        if words != nil { clear() }
    }
}
