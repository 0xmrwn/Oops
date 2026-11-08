import AppKit
import ServiceManagement
import SwiftUI

/// Onboarding's last step: where Oops lives now. A small card with Open at login (on, and visible,
/// so its state is a choice), then Done folds the window into the menu-bar eyes,
/// which answers "where did it go?" for an app with no Dock icon. Open at login is applied on Done.
@MainActor @Observable final class HomeStep {
    var openAtLogin: Bool
    /// Where the companion drop sits, in the window's own points: the fold starts there.
    private(set) var drop = CGRect.zero
    @ObservationIgnored let saves: Bool

    init(saves: Bool) {
        self.saves = saves
        // On the first run it starts on, as a choice to keep or undo; Show welcome shows it as it is.
        let registered = [.enabled, .requiresApproval].contains(SMAppService.mainApp.status)
        openAtLogin = !saves || registered || !OnboardingWindow.finished
    }

    /// Whether the eyes can be seen in the menu bar; when they can't, the fold ends low on screen.
    var eyesVisible: Bool {
        #if DEBUG
        if let eyes = previewEyes ?? DebugFlags.onboardingMenuBarEyes { return eyes }
        #endif
        return OnboardingWindow.shared.menuBar?.eyesFrame != nil
    }

    #if DEBUG
    /// Whether the eyes show, for `-SetupSnapshots`.
    @ObservationIgnored var previewEyes: Bool?
    #endif

    /// The companion's eyes: up at the menu bar, or down when the eyes are hidden.
    var look: CGSize { eyesVisible ? CGSize(width: 0.75, height: -0.75) : CGSize(width: 0, height: 0.6) }

    func noteDrop(_ rect: CGRect) { drop = rect }

    /// Done: the login item as chosen, then the fold.
    func finish() {
        if saves {
            OnboardingWindow.shared.markFinished()
            do {
                let registered = [.enabled, .requiresApproval].contains(SMAppService.mainApp.status)
                if openAtLogin, !registered { try SMAppService.mainApp.register() }
                if !openAtLogin, registered { try SMAppService.mainApp.unregister() }
            } catch {
                OnboardingWindow.shared.preferences?.status = "macOS didn’t change the login item. \(error.localizedDescription)"
            }
        }
        OnboardingWindow.shared.fold(drop: drop, look: look)
    }
}

/// The fold: the window fades while its drop flies up into the menu-bar eyes, which press once
/// as it lands. Hidden eyes: the drop settles where the drop appears without a draft, low on the
/// screen. With Reduce Motion it's only the fade.
@MainActor enum OnboardingFold {
    static func run(window: NSWindow, drop: CGRect, look: CGSize, eyes: CGRect?, greet: @escaping () -> Void, done: @escaping () -> Void) {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0.25 : 0.35
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
        }
        guard !reduceMotion, let content = window.contentView else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { greet(); done() }
            return
        }
        // The drop's rect on screen: SwiftUI's is top-left in the content view, AppKit's bottom-left.
        let start = window.convertToScreen(NSRect(x: drop.minX, y: content.bounds.height - drop.maxY, width: drop.width, height: drop.height))
        let screen = window.screen?.visibleFrame ?? start
        let target = eyes.map { CGRect(x: $0.midX - 9, y: $0.midY - 9, width: 18, height: 18) }
            ?? CGRect(x: screen.midX - 27, y: screen.minY + 90, width: 54, height: 54)
        let frame = start.union(target).insetBy(dx: -40, dy: -40)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false; panel.ignoresMouseEvents = true
        panel.level = .statusBar; panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        // In the panel's own top-left points.
        func local(_ rect: CGRect) -> CGRect { CGRect(x: rect.minX - frame.minX, y: frame.maxY - rect.maxY, width: rect.width, height: rect.height) }
        panel.contentView = NSHostingView(rootView: FoldingDrop(from: local(start), to: local(target), look: look, fades: eyes != nil))
        panel.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.72) { greet() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.95) { panel.orderOut(nil); done() }
    }
}

/// The drop in flight: it shrinks into the eyes, or settles low on the screen when they're hidden.
private struct FoldingDrop: View {
    let from: CGRect
    let to: CGRect
    let look: CGSize
    let fades: Bool
    @State private var flown = false
    @State private var faded = false

    var body: some View {
        let rect = flown ? to : from
        Color.clear.glassEffect(.clear, in: .circle)
            .overlay { DashEyes(look: look, lid: 0, ink: .white, halo: .black.opacity(0.35)).padding(rect.width * 0.08) }
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .opacity(faded ? 0 : 1)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onAppear {
                withAnimation(.spring(duration: 0.75, bounce: 0.12)) { flown = true }
                // Into the eyes it disappears as it arrives; low on screen it lingers a moment.
                withAnimation(.easeIn(duration: fades ? 0.2 : 0.3).delay(fades ? 0.55 : 0.7)) { faded = true }
            }
    }
}
