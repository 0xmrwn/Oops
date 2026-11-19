import AppKit
import OopsCore
import SwiftUI

/// The first-run window: Hello, then the setup steps. Shown on the first launch and from About →
/// Show welcome; like Settings, the app is a regular one (Dock icon, Command-Tab) only while it is open.
@MainActor final class OnboardingWindow: NSObject, NSWindowDelegate {
    static let shared = OnboardingWindow()
    /// Set by Home's Done or by closing the window. Until then every launch reopens onboarding at
    /// the step it left (`resumeKey`): quitting midway, or the relaunch Accessibility can need,
    /// doesn't leave Oops silent in the menu bar.
    static let finishedKey = "onboardingFinished"
    static let resumeKey = "onboardingStep"
    static var finished: Bool { UserDefaults.standard.bool(forKey: finishedKey) }
    /// Called once the window closes, so the app can ask for what onboarding didn't set up yet.
    var onClose: () -> Void = {}
    /// Where the setup steps save; nil in a `--hello-only` run beside a real Oops, which saves nothing.
    var preferences: Preferences?
    /// The Try it step, while onboarding is open.
    weak var tryIt: TryItStep?
    /// The menu-bar eyes the last step folds into; nil in a `--hello-only` run.
    weak var menuBar: MenuBar?
    /// Try it's draft while it's the one in front and corrects for real: the session reports there.
    var activeTry: TestEditorModel? {
        guard window?.isKeyWindow == true, let tryIt, tryIt.isLive else { return nil }
        return tryIt.fixture
    }
    private var window: NSWindow?
    private var presentation = WelcomePresentation()
    /// The feature a new-feature card is turning on: the window then runs only that feature's Shortcut and Try it.
    private var turningOn: OnboardingFeature?
    private var wallpaper: GradientRenderer?

    func show(turningOn feature: OnboardingFeature? = nil) {
        guard let window else {
            turningOn = feature
            let window = makeWindow()
            // The wallpaper's renderer is built before the window shows, so its first frame is never black.
            Task {
                wallpaper = await GradientMetalView.acquireRenderer()
                if self.window === window { front(window) }
            }
            return
        }
        front(window)
    }

    private func front(_ window: NSWindow) {
        NSApp.enterDock()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        presentation.visible = window.occlusionState.contains(.visible)
    }

    private func makeWindow() -> NSWindow {
        let screen = (NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        // Hello's 16:10 desktop at most 1080 wide, and never more than 80 % of the screen.
        var width = min(1080, screen.width * 0.8, screen.height * 0.8 * 1.6)
        #if DEBUG
        if DebugFlags.onboardingWindowWidth > 0 { width = DebugFlags.onboardingWindowWidth }
        #endif
        HelloZoom.window = width / HelloDraft.canvas.width
        presentation = WelcomePresentation()
        let controller = NSHostingController(rootView: OnboardingView(preferences: preferences, presentation: presentation, turningOn: turningOn,
                                                                      close: { [weak self] in self?.dismiss() })
            .focusRingsFromKeyboard())
        controller.sizingOptions = []
        let window = FocusRingsWindow(contentViewController: controller)
        window.title = "Welcome to Oops"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.setContentSize(NSSize(width: width, height: width * 0.625))
        window.setFrameOrigin(NSPoint(x: (screen.midX - width / 2).rounded(), y: (screen.midY - width * 0.3125).rounded()))
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.identifier = ShortcutStep.window
        self.window = window
        return window
    }

    /// The last step's Done: the window folds into the menu-bar eyes, then closes.
    func fold(drop: CGRect, look: CGSize) {
        guard let window else { return }
        OnboardingFold.run(window: window, drop: drop, look: look, eyes: menuBar?.eyesFrame,
                           greet: { [weak self] in self?.menuBar?.greet() }) { [weak window] in window?.close() }
    }

    /// The person closed onboarding (Escape or the close button): it counts as finished. Quitting
    /// the app closes nothing this way, so an unfinished onboarding comes back.
    private func dismiss() {
        markFinished()
        window?.close()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        markFinished()
        return true
    }

    func markFinished() {
        guard preferences != nil else { return }
        UserDefaults.standard.set(true, forKey: Self.finishedKey)
        UserDefaults.standard.removeObject(forKey: Self.resumeKey)
        UserDefaults.standard.removeObject(forKey: FeaturesStep.key)
        // First run offered every feature this build has: none of them is news later.
        NewFeatures.markAnnounced(NewFeatures.offered)
    }

    /// Closing ends Hello (its sounds included) and releases the window, as Settings does.
    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === window else { return }
        presentation.visible = false
        window = nil; turningOn = nil; wallpaper = nil
        NSApp.leaveDockUnlessOtherWindows(than: closing)
        DispatchQueue.main.async { [weak self] in
            closing.contentViewController = nil
            if self?.window == nil { self?.onClose() }
        }
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let changed = notification.object as? NSWindow, changed === window else { return }
        presentation.visible = changed.occlusionState.contains(.visible)
    }
}

@MainActor @Observable final class WelcomePresentation {
    var visible = false
}
