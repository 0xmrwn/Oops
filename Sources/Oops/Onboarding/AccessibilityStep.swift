import AppKit
import SwiftUI

/// Onboarding's Accessibility step, DaisyDisk's and PermissionFlow's pattern: the drop is what you
/// drag into System Settings' Accessibility list. Grabbing it (or Open System Settings) opens the
/// pane; while System Settings is in front, a helper docked under its window carries a second drop,
/// and the window's drop watches it. Once macOS reports the permission, the eyes become a check and
/// onboarding comes back to the front. Nothing is inferred from opening Settings: only the system's
/// answer moves the step on.
@MainActor @Observable final class AccessibilityStep {
    enum Phase: Equatable { case waiting, inSettings, granted }

    static let pane = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility")!
    /// What System Settings calls that list: macOS 27 renamed it (checked on 27.0).
    static var paneName: String { renamedPane ? "Device Control and Data Access" : "Accessibility" }
    /// The symbol on the pane's blue tile: 27's `privacy-accessibility` icon in Privacy & Security's
    /// Info.plist, and the Accessibility figure before it.
    static var paneSymbol: String { renamedPane ? "folder.badge.gearshape" : "accessibility" }

    private static var renamedPane: Bool {
        if #available(macOS 27, *) { !DebugFlags.onboardingOlderPane } else { false }
    }

    private(set) var phase = Phase.waiting
    /// The drop is in the pointer's hand: the window's own copy steps aside.
    private(set) var carried = false
    private(set) var hovering = false
    /// The drop's eyes, in `DashEyes` units: down at the list, then at System Settings, then a check.
    private(set) var look = CGSize(width: 0, height: 0.75)
    private(set) var lid = 0.0
    private(set) var check = 0.0

    @ObservationIgnored private let helper = AccessibilityHelper()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var ticks = 0
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var simulatedAt: ContinuousClock.Instant?
    /// System Settings has been behind since the step started: a window already in front when it
    /// began isn't one the person opened from here.
    @ObservationIgnored private var settingsWasBehind = false

    init() {
        helper.onBegin = { [weak self] in self?.carried = true }
        helper.onEnd = { [weak self] in self?.carried = false }
        helper.onClick = { [weak self] in self?.openSettings() }
        if trusted { phase = .granted; check = 1; look = .zero }
    }

    /// The permission as macOS reports it. Debug builds can hide a granted one
    /// (`--preview-missing-accessibility`) and grant it that many seconds after System Settings opens
    /// (`-SimulateAccessibilityGrant 4`), so the step can be seen without changing the real setting.
    private var trusted: Bool {
        #if DEBUG
        if DebugFlags.missingAccessibility { return simulatedAt.map { $0 <= .now } ?? false }
        #endif
        return AXIsProcessTrusted()
    }

    func start() {
        guard timer == nil, phase != .granted else { return }
        // 30 Hz keeps the helper on the window while it's dragged around; the permission is asked
        // about less often, and at once when the system says Accessibility changed.
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        observer = DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.apple.accessibility.api"),
                                                                       object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkTrust() }
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
        observer = nil
        helper.hide()
    }

    // MARK: Actions

    func openSettings() {
        guard phase != .granted else { return }
        NSWorkspace.shared.open(Self.pane)
        enterSettings()
    }

    /// Grabbing the drop opens the pane, so the list is there by the time the pointer reaches it.
    func dragBegan() {
        carried = true
        if phase == .waiting { openSettings() }
    }

    func dragEnded() { withAnimation(.spring(duration: 0.35)) { carried = false } }

    func hover(_ inside: Bool) { withAnimation(.spring(duration: 0.3, bounce: 0.3)) { hovering = inside } }

    #if DEBUG
    /// Sets a moment directly, for `-SetupSnapshots`.
    func seed(_ phase: Phase) {
        self.phase = phase
        check = phase == .granted ? 1 : 0
        look = phase == .granted ? .zero : phase == .inSettings ? CGSize(width: 0.9, height: -0.2) : CGSize(width: 0, height: 0.75)
    }
    #endif

    // MARK: Watching

    private func enterSettings() {
        guard phase == .waiting else { return }
        withAnimation(.spring(duration: 0.5, bounce: 0.2)) { phase = .inSettings }
        #if DEBUG
        if DebugFlags.missingAccessibility, simulatedAt == nil, DebugFlags.simulatedAccessibilityGrant > 0 {
            simulatedAt = .now + .seconds(DebugFlags.simulatedAccessibilityGrant)
        }
        #endif
    }

    private func tick() {
        ticks += 1
        if ticks.isMultiple(of: 8) { checkTrust() }
        guard phase != .granted else { return }
        let front = SystemSettingsWindow.isFrontmost
        if !front { settingsWasBehind = true }
        let frame = front ? SystemSettingsWindow.frame : nil
        // Opened some other way (the system's own prompt, the Dock): the step follows along.
        if frame != nil, settingsWasBehind { enterSettings() }
        helper.place(under: phase == .inSettings ? frame : nil)
        // Behind onboarding, the window is looked up less often; in front, its frame is already known.
        if phase == .inSettings, let target = frame ?? (ticks.isMultiple(of: 8) ? SystemSettingsWindow.frame : nil) { watch(target) }
    }

    /// The eyes turn toward System Settings, wherever it is relative to onboarding's window.
    private func watch(_ target: CGRect) {
        guard let window = NSApp.windows.first(where: { $0.identifier == ShortcutStep.window }) else { return }
        let dx = target.midX - window.frame.midX, dy = target.midY - window.frame.maxY + 140
        let length = max(hypot(dx, dy), 1)
        let next = CGSize(width: dx / length, height: -dy / length * 0.8)
        guard abs(next.width - look.width) > 0.02 || abs(next.height - look.height) > 0.02 else { return }
        withAnimation(.spring(duration: 0.5, bounce: 0.15)) { look = next }
    }

    private func checkTrust() {
        guard phase != .granted, trusted else { return }
        withAnimation(.spring(duration: 0.55, bounce: 0.3)) { phase = .granted; check = 1; lid = 0; look = .zero }
        helper.hide()
        timer?.invalidate(); timer = nil
        Sounds.shared.play(.success, after: 0)
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: "Oops is allowed", .priority: NSAccessibilityPriorityLevel.high.rawValue])
        // Back to onboarding, where Continue now waits.
        NSApp.activate()
        NSApp.windows.first { $0.identifier == ShortcutStep.window }?.makeKeyAndOrderFront(nil)
    }
}

/// The helper docked under System Settings' window: a second drop to drag, pointing up at the list.
/// Accent-tinted so it stands apart from the list it sits beside; it never takes focus, so System
/// Settings stays the app in front.
@MainActor private final class AccessibilityHelper {
    var onBegin: () -> Void = {}
    var onEnd: () -> Void = {}
    var onClick: () -> Void = {}
    /// The panel, with room around the capsule for its shadow and the drop's pulse.
    private static let size = CGSize(width: 400, height: 112)
    private lazy var panel: NSPanel = makePanel()
    private var shown = false

    /// Docks under the window's content area (right of its sidebar); hides when there's no window.
    func place(under frame: CGRect?) {
        guard let frame else { return hide() }
        let screen = NSScreen.screens.first { $0.frame.intersects(frame) }?.visibleFrame ?? frame
        let sidebar = min(230, frame.width * 0.32)
        var origin = CGPoint(x: frame.minX + sidebar + (frame.width - sidebar - Self.size.width) / 2, y: frame.minY - Self.size.height + 6)
        origin.x = min(max(origin.x, screen.minX), screen.maxX - Self.size.width)
        origin.y = max(origin.y, screen.minY)
        let target = CGRect(origin: origin, size: Self.size)
        if !shown {
            shown = true
            // A fresh view each time, so the capsule springs in again.
            panel.contentView = NSHostingView(rootView: AccessibilityHelperView(
                onBegin: { [weak self] in self?.onBegin() }, onEnd: { [weak self] in self?.onEnd() }, onClick: { [weak self] in self?.onClick() }))
            panel.setFrame(target, display: false)
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        } else if panel.frame != target {
            panel.setFrame(target, display: true)
        }
    }

    func hide() {
        guard shown else { return }
        shown = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated { if self?.shown == false { self?.panel.orderOut(nil) } }
        }
    }

    private func makePanel() -> NSPanel {
        let panel = HelperPanel(contentRect: CGRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.level = .floating; panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.title = "Oops Accessibility helper"
        return panel
    }
}

private final class HelperPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The helper's content: the drop, pulsing to say it can be picked up, what to do with it and an
/// arrow nudging up at the list, on accent glass. It springs up into place when it docks.
struct AccessibilityHelperView: View {
    let onBegin: () -> Void
    let onEnd: () -> Void
    let onClick: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @State private var carried = false
    @State private var arrived: Bool
    @State private var pulse = false

    /// `arrived` skips the spring in, for `-SetupSnapshots`, where nothing appears.
    init(onBegin: @escaping () -> Void, onEnd: @escaping () -> Void, onClick: @escaping () -> Void, arrived: Bool = false) {
        self.onBegin = onBegin; self.onEnd = onEnd; self.onClick = onClick
        _arrived = State(initialValue: arrived)
    }

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().stroke(.white.opacity(pulse ? 0 : 0.6), lineWidth: 2)
                    .scaleEffect(pulse ? 1.5 : 1)
                Color.clear.glassEffect(.clear.interactive(), in: .circle)
                DashEyes(look: CGSize(width: 0, height: -0.8), lid: 0, ink: .white, halo: .black.opacity(0.3)).padding(10)
                // Offscreen snapshots can't draw an AppKit view.
                if DebugFlags.setupSnapshots == nil {
                    DropDragSource(onBegin: { carried = true; onBegin() }, onEnd: { carried = false; onEnd() }, onClick: onClick,
                                   onHover: { inside in withAnimation(.spring(duration: 0.3, bounce: 0.3)) { hovering = inside } })
                }
            }
            .frame(width: 54, height: 54)
            .scaleEffect(hovering && !carried ? 1.08 : 1)
            .opacity(carried ? 0.35 : 1)
            // First-timers don't know the drop is the app: other helpers (PermissionFlow, AskForPermission)
            // say where it goes. A glyph halo, not a plate, keeps it on any accent.
            Text("Drag \(Text(verbatim: "Oops").fontWeight(.bold)) into the list above").font(.system(size: 15, weight: .medium))
                .lineLimit(1).fixedSize()
                .shadow(color: .black.opacity(0.3), radius: 2)
            Spacer(minLength: 0)
            Image(systemName: "arrow.up").font(.system(size: 18, weight: .bold))
                .shadow(color: .black.opacity(0.3), radius: 2)
                .offset(y: pulse && !reduceMotion ? -4 : 2)
                .accessibilityHidden(true)
        }
        .foregroundStyle(.white)
        .padding(.leading, 10).padding(.trailing, 22)
        .frame(width: 350, height: 74)
        // Behind the content rather than around it: offscreen snapshots drop whatever glass wraps.
        .background { Color.clear.glassEffect(.regular.tint(.accentColor.opacity(0.8)), in: .capsule) }
        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
        .scaleEffect(arrived ? 1 : 0.7)
        .offset(y: arrived ? 0 : 24)
        .opacity(arrived ? 1 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.55, bounce: 0.4)) { arrived = true }
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 1.3).repeatForever(autoreverses: false).delay(0.5)) { pulse = true }
        }
    }
}
