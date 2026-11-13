import AppKit
import Metal
import OopsCore
import QuartzCore

// A port of the dot scope voice visualizer of Hex (github.com/anomalyco/hex, `ios/HEXShared/DotScope.swift` at
// v3.4.0; MIT, Copyright (c) 2026 Christopher Langton), from UIKit to AppKit. See THIRD_PARTY_NOTICES.md.

/// Retains nothing of the view: a display link keeps its target alive until it is invalidated.
final class DisplayLinkProxy: NSObject {
    var tickHandler: ((CADisplayLink) -> Void)?

    @MainActor
    @objc func tick(_ link: CADisplayLink) {
        tickHandler?(link)
    }
}

// MARK: - `DotScopeHostView`

/// The scope's view: a Metal layer that the view feeds from a `DotScopeSimulation` on its own display link.
/// The link runs only while there is something to draw (see `updateAnimatingState`), so a settled or hidden
/// scope costs nothing. The caller sets `phase`, `loudnessProvider` (decibels, read once per frame), `isDark`
/// and `reduceMotion`.
@MainActor
final class DotScopeHostView: NSView {
    private let simulation: DotScopeSimulation
    private var requestedTuning: DotScopeTuning
    private var hasFittedInitialLayout = false
    private let renderer: DotScopeRenderer?
    private let proxy = DisplayLinkProxy()
    private var displayLink: CADisplayLink?
    private var lastTargetTimestamp: CFTimeInterval?
    private var hasSeededSnapshot = false
    private var visibilityObservations: [NSKeyValueObservation] = []
    private var visibilityRefreshScheduled = false

    var phase: DotScopePhase = .hidden {
        didSet {
            guard phase != oldValue else { return }
            handlePhaseChange(from: oldValue, to: phase)
        }
    }

    var isDark = true {
        didSet {
            if isDark != oldValue {
                renderCurrentFrame()
            }
        }
    }

    /// Oops draws the scope straight onto the capsule's glass, so the plate (and its rim and shadow) is off
    /// unless a caller asks for it; the original draws it by default.
    var drawPlate = false {
        didSet {
            if drawPlate != oldValue {
                renderCurrentFrame()
            }
        }
    }

    var reduceMotion = false
    var useDemoVoice = false
    var loudnessProvider: (() -> Float)?

    /// Exposed for unit tests to verify simulation continuity across live meter updates.
    var debugElapsedTime: Float { simulation.elapsedTime }
    var debugIsPaused: Bool { displayLink?.isPaused ?? true }

    private var metalLayer: CAMetalLayer? { layer as? CAMetalLayer }

    /// The screen's pixels per point; the original reads `traitCollection.displayScale`.
    private var displayScale: CGFloat { max(1.0, window?.backingScaleFactor ?? 1.0) }

    init(tuning: DotScopeTuning) {
        self.requestedTuning = tuning
        self.simulation = DotScopeSimulation(tuning: tuning)
        self.renderer = DotScopeRenderer()
        super.init(frame: .zero)

        wantsLayer = true
        if let metalLayer, let renderer {
            renderer.configure(metalLayer)
        }

        proxy.tickHandler = { [weak self] link in
            self?.stepAndRender(timestamp: link.timestamp, targetTimestamp: link.targetTimestamp)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func makeBackingLayer() -> CALayer { CAMetalLayer() }

    override var isOpaque: Bool { false }

    /// The scope is decoration: clicks and hovers go to what is behind it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// True while inside a window and every ancestor layer has opacity > 0 and isn't hidden.
    /// Keeps rendering live pixels while fading out, and pauses cleanly once opacity reaches 0.
    var isEffectivelyVisible: Bool {
        guard window != nil else { return false }
        var current: NSView? = self
        while let view = current {
            if view.isHidden || (view.layer?.opacity ?? 1) <= 0.001 {
                return false
            }
            current = view.superview
        }
        return true
    }

    private func observeVisibility() {
        visibilityObservations.removeAll()
        var ancestor: NSView? = self
        while let view = ancestor {
            visibilityObservations.append(
                view.observe(\.isHidden, options: [.new]) { [weak self] _, _ in
                    Task { @MainActor [weak self] in
                        self?.updateAnimatingState()
                    }
                }
            )
            if let layer = view.layer {
                visibilityObservations.append(
                    layer.observe(\.opacity, options: [.new]) { [weak self] _, _ in
                        Task { @MainActor [weak self] in
                            self?.updateAnimatingState()
                        }
                    }
                )
            }
            ancestor = view.superview
        }
    }

    func scheduleVisibilityRefresh() {
        guard !visibilityRefreshScheduled else { return }
        visibilityRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.visibilityRefreshScheduled = false
            self.observeVisibility()
            self.updateAnimatingState()
        }
    }

    func updateTuning(_ tuning: DotScopeTuning) {
        guard requestedTuning != tuning else { return }
        requestedTuning = tuning
        applyEffectiveTuning(jumpLayout: !hasFittedInitialLayout)
        updateAnimatingState()
        if displayLink?.isPaused != false {
            renderCurrentFrame()
        }
    }

    private func applyEffectiveTuning(jumpLayout: Bool) {
        let scale = Float(displayScale)
        let pxW = Int((bounds.width * CGFloat(scale)).rounded())
        let pxH = Int((bounds.height * CGFloat(scale)).rounded())
        let effective = requestedTuning.fitted(pixelWidth: pxW, pixelHeight: pxH, scale: scale)
        simulation.tune(effective, jumpLayout: jumpLayout)
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        observeVisibility()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            needsLayout = true
            observeVisibility()
            ensureDisplayLink()
            updateAnimatingState()
            renderCurrentFrame()
        } else {
            visibilityObservations.removeAll()
            displayLink?.invalidate()
            displayLink = nil
            lastTargetTimestamp = nil
        }
    }

    /// A move to a screen with another scale changes the drawable's pixel size without changing the bounds.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard let metalLayer else { return }
        let scale = displayScale
        metalLayer.contentsScale = scale
        let pixelSize = CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
        let sizeChanged = metalLayer.drawableSize != pixelSize
        if sizeChanged {
            metalLayer.drawableSize = pixelSize
        }
        if pixelSize.width > 8 && pixelSize.height > 8 {
            let isFirstFit = !hasFittedInitialLayout
            hasFittedInitialLayout = true
            // Jump inset springs ONLY on the very first fit from zero; subsequent layout passes glide smoothly.
            applyEffectiveTuning(jumpLayout: isFirstFit)
            if isFirstFit, phase == .idle {
                settleIdleImmediately()
            }
        }
        seedForSnapshotIfNeeded()
        updateAnimatingState()
        if sizeChanged || displayLink?.isPaused != false {
            // UIKit presents with a transaction only inside an animation; AppKit has no such signal, so every
            // resize keeps the drawable in step with the layout.
            renderCurrentFrame(withTransaction: sizeChanged)
        }
    }

    private func ensureDisplayLink() {
        guard displayLink == nil else { return }
        let link = displayLink(target: proxy, selector: #selector(DisplayLinkProxy.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.isPaused = true
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    /// The idle pre-roll only exists so previews and snapshots open on a settled scope.
    private func settleIdleImmediately() {
        for _ in 0..<42 {
            simulation.advance(
                dt: 1.0 / 60.0,
                stage: .idle,
                visible: true,
                loudness: -120.0,
                reduceMotion: reduceMotion
            )
        }
    }

    private func handlePhaseChange(from old: DotScopePhase, to next: DotScopePhase) {
        if old == .hidden, next != .hidden, simulation.settled {
            simulation.restart(reduceMotion: reduceMotion)
            if next == .idle {
                settleIdleImmediately()
            }
        }
        seedForSnapshotIfNeeded()
        updateAnimatingState()
        if displayLink?.isPaused != false {
            renderCurrentFrame()
        }
    }

    private func seedForSnapshotIfNeeded() {
        guard useDemoVoice, !hasSeededSnapshot, bounds.width > 8 else { return }
        switch phase {
        case .hidden, .idle:
            return
        case .recording, .processing, .failed:
            break
        }
        hasSeededSnapshot = true
        let dt: Float = 1.0 / 60.0
        for _ in 0..<48 {
            simulation.advance(
                dt: dt,
                stage: .recording,
                visible: true,
                loudness: -27.5 + 5.0 * sin(simulation.elapsedTime * 21.0),
                reduceMotion: false
            )
        }
        if phase == .processing {
            for _ in 0..<28 {
                simulation.advance(
                    dt: dt,
                    stage: .processing,
                    visible: true,
                    loudness: -120.0,
                    reduceMotion: false
                )
            }
        }
    }

    private func updateAnimatingState() {
        let visible = isEffectivelyVisible
        let wantsFrames: Bool
        if !visible {
            wantsFrames = false
        } else {
            wantsFrames = switch phase {
            case .hidden:
                !simulation.settled
            case .idle:
                !simulation.isIdleSettled
            case .recording, .processing, .failed:
                true
            }
        }
        let targetPaused = !wantsFrames
        if displayLink?.isPaused != targetPaused {
            if !targetPaused {
                lastTargetTimestamp = nil
            }
            displayLink?.isPaused = targetPaused
        }
    }

    func stepAndRender(timestamp: CFTimeInterval, targetTimestamp: CFTimeInterval) {
        let dt: Float
        if let prevTarget = lastTargetTimestamp {
            dt = Float(min(0.05, max(1.0 / 240.0, targetTimestamp - prevTarget)))
        } else {
            dt = Float(min(0.05, max(1.0 / 240.0, targetTimestamp - timestamp)))
        }
        lastTargetTimestamp = targetTimestamp

        let (stage, visible, loudness) = simulationInputs()
        simulation.advance(
            dt: dt,
            stage: stage,
            visible: visible,
            loudness: loudness,
            reduceMotion: reduceMotion
        )
        renderCurrentFrame()
        updateAnimatingState()
    }

    private func simulationInputs() -> (DotScopeStage, Bool, Float) {
        switch phase {
        case .hidden:
            return (.done, false, -120.0)
        case .idle:
            return (.idle, true, -120.0)
        case .recording:
            let liveDB = loudnessProvider?() ?? -62.0
            let effectiveDB: Float
            if useDemoVoice, liveDB <= -80.0 {
                effectiveDB = DotScopeSimulation.demoLoudness(at: simulation.elapsedTime) + 4.5
            } else {
                effectiveDB = liveDB
            }
            return (.recording, true, effectiveDB)
        case .processing:
            return (.processing, true, -120.0)
        case .failed:
            return (.failed, true, -120.0)
        }
    }

    private func renderCurrentFrame(withTransaction: Bool = false) {
        guard bounds.width > 1, bounds.height > 1, let metalLayer, let renderer else { return }
        renderer.render(simulation, into: metalLayer, isDark: isDark, drawPlate: drawPlate, withTransaction: withTransaction)
    }
}
