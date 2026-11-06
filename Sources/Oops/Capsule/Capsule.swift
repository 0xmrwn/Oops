import AppKit
import SwiftUI
import OopsCore

enum CapsulePhase: Equatable { case invoked, working, fixed, pending, copied, failed, reverted }
@MainActor final class CapsuleModel: ObservableObject {
    @Published var phase: CapsulePhase = .invoked
    @Published var label = ""
    @Published var detail = ""
    @Published var canRevert = false
    @Published var canCancel = true
    /// What the failed drop offers next to its reason.
    @Published var remedy: Remedy?
    /// The pending drop's copy button has been pressed; its icon turns into a check.
    @Published var copied = false
    /// Drives the drop's entrance and exit; the panel stays up until the exit has played.
    @Published var presented = false
    /// Which panel corner the capsule hugs, from the placement engine.
    @Published var alignment: Alignment = .bottom
    /// The pointer is over the drop: it holds a timed dismissal and shows the close badge.
    @Published var hovering = false
    /// The drop's target width, set by the view, so the panel knows where the pointer counts as over it.
    var width: CGFloat = 46
    var cancel: (() -> Void)?
    var revert: (() -> Void)?
    var copy: (() -> Void)?
    var retry: (() -> Void)?
    var openSettings: (() -> Void)?
    var dismiss: (() -> Void)?
    enum Remedy { case retry, settings }
}

/// The drop's buttons answer the first click: the panel never becomes key and oops stays in the
/// background, so without this AppKit would spend that click on activation.
extension DropState {
    init(_ phase: CapsulePhase) {
        switch phase {
        case .invoked, .working: self = .starting
        case .fixed: self = .fixed
        case .failed, .pending: self = .failed
        case .copied, .reverted: self = .quiet
        }
    }
}

private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class PassivePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor final class CapsulePanel {
    private static let size = CGSize(width: 280, height: 78)
    /// EyesDropView pads its glass by this much inside the panel.
    private static let inset: CGFloat = 14
    let model = CapsuleModel()
    private let panel: NSPanel
    private var geometry: CapsulePlacement.Geometry?
    private(set) var placement: CapsulePlacement.Placement?
    private let tracker = WindowTracker()
    private var resample: Task<Void, Never>?
    init() {
        panel = PassivePanel(contentRect: NSRect(origin: .zero, size: Self.size),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.title = "Oops Capsule"
        panel.level = .floating; panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        // Debug-only, for design recordings: force the capsule's appearance.
        if let appearance = DebugFlags.capsuleAppearance {
            panel.appearance = NSAppearance(named: appearance == "light" ? .aqua : .darkAqua)
        }
        // The initial icon-only phase has a smaller ideal width. Keep hosting
        // geometry stable so AppKit does not compress later status text away.
        panel.contentView = FirstClickHostingView(rootView: CapsuleRoot(model: model, size: Self.size))
    }
    /// `spoken` replaces the label in the VoiceOver announcement, for labels that read badly aloud.
    func show(_ phase: CapsulePhase, label: String, detail: String = "", remedy: CapsuleModel.Remedy? = nil,
              spoken: String? = nil, geometry: CapsulePlacement.Geometry? = nil) {
        if let geometry { self.geometry = geometry; neutral = false }
        let entering = !panel.isVisible || hiding != nil
        let previous = entering ? nil : DropState(model.phase)
        hiding?.cancel(); hiding = nil; lingering?.cancel(); lingering = nil
        model.phase = phase; model.label = label; model.detail = detail; model.remedy = remedy
        // An entering drop presents one frame later (below), so its cue waits that frame too.
        if let played = SoundCues.cue(from: previous, to: DropState(phase), reduceMotion: Self.reduceMotion) {
            Sounds.play(played.cue, after: played.delay + (entering ? 0.016 : 0))
        }
        if phase != .copied { model.copied = false }
        position(); panel.orderFrontRegardless(); trackPointer()
        // One frame later, so the drop's small, transparent start state is rendered before it pops in.
        if entering, !model.presented { DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { self.model.presented = true } } else { model.presented = true }
        if phase != .invoked, phase != .working {
            NSAccessibility.post(element: panel, notification: .announcementRequested,
                                 userInfo: [.announcement: spoken ?? label, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        }
    }
    /// Re-anchors while visible when the editor's window moves or resizes; drags are coalesced.
    /// A pending drop can outlive draft recovery, so its sampler only needs the element.
    func follow(_ element: AXUIElement, sample: @escaping @MainActor (AXUIElement) async -> CapsulePlacement.Geometry) {
        cancelResample()
        tracker.track(element) { [weak self] in
            guard let self, self.isShown, self.resample == nil else { return }
            self.resample = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .milliseconds(60)) } catch { return }
                guard !Task.isCancelled else { return }
                // Cancellation already cleared this slot; a newer sample may now own it.
                defer { if !Task.isCancelled { self?.resample = nil } }
                guard self?.isShown == true else { return }
                let geometry = await sample(element)
                guard !Task.isCancelled, let self, self.isShown else { return }
                self.geometry = geometry; self.position()
            }
        }
    }

    private func cancelResample() {
        resample?.cancel()
        resample = nil
    }

    var isShown: Bool { panel.isVisible && hiding == nil }
    /// The drop's motions become fades, so the cues' leads shrink with them.
    private static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || EyesDropView.forced.contains("reduce-motion")
    }
    /// Placed at the neutral spot instead of at the draft.
    private var neutral = false
    /// The draft's window is no longer in front, so its spot may now be over another app: the drop
    /// leaves it for the neutral spot, low and centred on the screen the draft was on, fading across.
    func unanchor() {
        guard !neutral else { return }
        tracker.stop(); cancelResample(); neutral = true
        guard panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.12; panel.animator().alphaValue = 0 }) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.position()
                NSAnimationContext.runAnimationGroup { $0.duration = 0.18; self.panel.animator().alphaValue = 1 }
            }
        }
    }
    private var hiding: DispatchWorkItem?
    private var lingering: Task<Void, Never>?
    /// Hides after `seconds`, held while the pointer rests on the drop and a moment after it
    /// leaves, so its buttons stay in reach.
    func hide(after seconds: Double) {
        lingering?.cancel()
        lingering = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            while !Task.isCancelled, let hold = self?.hold, hold > 0 { try? await Task.sleep(for: .seconds(hold)) }
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }
    private var leftAt: Date?
    /// How much longer a timed hide waits: while the pointer is on the drop, and 0.8 s after it
    /// leaves, even when it left just before the deadline.
    private var hold: Double {
        if model.hovering { return 0.2 }
        guard let leftAt else { return 0 }
        return max(0, 0.8 - Date().timeIntervalSince(leftAt))
    }
    /// Keeps the drop up: a new correction or revert is about to replace it.
    func cancelTimedHide() { lingering?.cancel(); lingering = nil }
    private var pointer: Timer?
    /// Samples the pointer while the drop is up. Polled rather than tracked: the panel never
    /// activates, and a sample is a rect test ten times a second.
    private func trackPointer() {
        guard pointer == nil else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let inside = self.dropFrame.contains(NSEvent.mouseLocation)
                guard self.model.hovering != inside else { return }
                self.model.hovering = inside
                if !inside { self.leftAt = Date() }
            }
        }
        RunLoop.main.add(timer, forMode: .common); pointer = timer
    }
    /// The drop inside the panel, in screen points, with room for the close badge on its rim.
    private var dropFrame: NSRect {
        let area = panel.frame.insetBy(dx: Self.inset, dy: Self.inset), width = model.width, height = EyesDropView.drop
        let x = switch model.alignment.horizontal {
        case .leading: area.minX
        case .trailing: area.maxX - width
        default: area.midX - width / 2
        }
        let y = model.alignment.vertical == .top ? area.maxY - height : area.minY
        return NSRect(x: x, y: y, width: width, height: height).insetBy(dx: -3, dy: -3)
    }
    /// Copy feedback without words: the button's icon becomes a check, then the drop folds into
    /// the eyes' own check and leaves.
    func confirmCopy() {
        cancelTimedHide(); model.copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [self] in
            guard model.copied, model.phase == .pending else { return }
            show(.copied, label: model.label, spoken: "Copied"); hide(after: 0.9)
        }
    }
    /// Plays the exit (the drop shrinks out) before removing the panel.
    /// Called as the drop starts to leave, so whatever belongs to it (the flash) leaves too.
    var onHide: (() -> Void)?

    func hide() {
        onHide?()
        tracker.stop(); cancelResample(); lingering?.cancel(); lingering = nil
        guard panel.isVisible, hiding == nil else { return }
        model.presented = false
        let removal = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.panel.orderOut(nil); self.geometry = nil; self.hiding = nil; self.neutral = false; self.panel.alphaValue = 1
            self.pointer?.invalidate(); self.pointer = nil; self.model.hovering = false; self.leftAt = nil
        }
        hiding = removal
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: removal)
    }
    /// The engine works in AX coordinates (top-left, global, primary display); AppKit is bottom-left.
    private func position() {
        let primary = NSScreen.screens.first?.frame.maxY ?? 900
        let screens = NSScreen.screens.map { s in CGRect(x: s.visibleFrame.minX, y: primary - s.visibleFrame.maxY,
                                                         width: s.visibleFrame.width, height: s.visibleFrame.height) }
        let envelope = CGSize(width: Self.size.width - 2 * Self.inset, height: Self.size.height - 2 * Self.inset)
        let placement = neutral
            ? CapsulePlacement.place(nil, envelope: envelope, screens: draftScreen(in: screens).map { [$0] } ?? screens)
            : CapsulePlacement.place(geometry, envelope: envelope, screens: screens)
        self.placement = placement
        model.alignment = switch placement.corner {
        case .bottomTrailing: .bottomTrailing
        case .topTrailing: .topTrailing
        case .bottomLeading: .bottomLeading
        case .topLeading: .topLeading
        case .bottom: .bottom
        }
        let rect = placement.envelope.insetBy(dx: -Self.inset, dy: -Self.inset)
        panel.setFrame(NSRect(x: rect.minX, y: primary - rect.maxY, width: rect.width, height: rect.height), display: true)
    }
    /// The screen most of the draft's window was on, in the engine's coordinates.
    private func draftScreen(in screens: [CGRect]) -> CGRect? {
        guard let anchor = geometry?.window ?? geometry?.element else { return nil }
        func overlap(_ screen: CGRect) -> CGFloat { let i = screen.intersection(anchor); return i.isNull ? 0 : i.width * i.height }
        return screens.max { overlap($0) < overlap($1) }.flatMap { overlap($0) > 0 ? $0 : nil }
    }
}

/// Keeps the capsule hugging the placement's corner inside the fixed-size panel.
private struct CapsuleRoot: View {
    @ObservedObject var model: CapsuleModel
    let size: CGSize
    var body: some View {
        EyesDropView(model: model)
            .frame(width: size.width, height: size.height, alignment: model.alignment)
    }
}
