import AppKit
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

    func show() {
        let window = window ?? makeWindow()
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
        let controller = NSHostingController(rootView: OnboardingView(preferences: preferences, presentation: presentation,
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
    }

    /// Closing ends Hello (its sounds included) and releases the window, as Settings does.
    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === window else { return }
        presentation.visible = false
        window = nil
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

@MainActor @Observable private final class WelcomePresentation {
    var visible = false
}

private struct OnboardingView: View {
    enum Step: String {
        case hello, provider, shortcut, accessibility, tryIt, home
        /// The steps after Hello, which the dots count.
        static let setup: [Step] = [.provider, .shortcut, .accessibility, .tryIt, .home]
    }
    let close: () -> Void
    let presentation: WelcomePresentation
    /// A first run not finished yet: it remembers its step. Show welcome replays from Hello and remembers nothing.
    private let resumable: Bool
    /// The step an unfinished onboarding left off at, which it reopens at instead of Hello.
    private let resume: Step?
    @State private var director = HelloDirector()
    @State private var providers: ProviderStep
    @State private var shortcut: ShortcutStep
    @State private var accessibility = AccessibilityStep()
    @State private var tryIt: TryItStep
    @State private var home: HomeStep
    @State private var step = Step.hello
    /// The companion drop has left Hello's finale for the step's header.
    @State private var dropAtStep = false
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || DebugFlags.brandReduceMotion }

    init(preferences: Preferences?, presentation: WelcomePresentation, close: @escaping () -> Void) {
        self.presentation = presentation
        _providers = State(initialValue: ProviderStep(preferences: preferences))
        let shortcut = ShortcutStep(saves: preferences != nil)
        _shortcut = State(initialValue: shortcut)
        // Try it's Change records with the Shortcut step's own recorder.
        _tryIt = State(initialValue: TryItStep(preferences: preferences, shortcuts: shortcut))
        _home = State(initialValue: HomeStep(saves: preferences != nil))
        self.close = close
        resumable = preferences != nil && !OnboardingWindow.finished
        resume = resumable ? UserDefaults.standard.string(forKey: OnboardingWindow.resumeKey).flatMap(Step.init(rawValue:)) : nil
    }

    var body: some View {
        ZStack {
            HelloScene(director: director, handedOff: step != .hello, visible: presentation.visible) { begin() }
                .disabled(step != .hello)
                // Behind a setup step Hello is wallpaper: VoiceOver reads the step, not Hello's drops.
                .accessibilityHidden(step != .hello)
            switch step {
            case .hello: EmptyView()
            case .provider:
                ProviderStepView(step: providers, next: { withAnimation(.easeInOut(duration: 0.45)) { step = .shortcut } })
                    .transition(.opacity.animation(.easeOut(duration: 0.45).delay(0.3)))
            case .shortcut:
                ShortcutStepView(step: shortcut) { withAnimation(.easeInOut(duration: 0.45)) { step = .accessibility } }
                    .transition(.opacity)
            case .accessibility:
                AccessibilityStepView(step: accessibility) { withAnimation(.easeInOut(duration: 0.45)) { step = .tryIt } }
                    .transition(.opacity)
            case .tryIt:
                TryItStepView(step: tryIt) { withAnimation(.easeInOut(duration: 0.45)) { step = .home } }
                    .transition(.opacity)
            case .home:
                HomeStepView(step: home).transition(.opacity)
            }
            if step != .hello {
                OnboardingProgress(steps: Step.setup.count, current: Step.setup.firstIndex(of: step) ?? 0)
                    .onboardingFooterRow(.center)
                    .transition(.opacity)
            }
            // Escape skips Hello to Set up, then closes. Out of the Tab loop: an invisible stop that Space
            // pressed would close onboarding.
            Button("") { if step == .provider, providers.showingAPI { providers.backFromAPI() }
                else if step == .hello, director.stage != .finale { director.skip() }
                else { close() }
            }
                .keyboardShortcut(.cancelAction).focusable(false).opacity(0).accessibilityHidden(true)
        }
        .overlayPreferenceValue(OnboardingDropKey.self) { anchors in
            GeometryReader { proxy in
                // Try it has the real drop, over its composer.
                if step != .hello, step != .tryIt, let anchor = anchors[dropAtStep ? "step" : "finale"] { companion(in: proxy[anchor]) }
            }
            .allowsHitTesting(false)
        }
        .onAppear {
            OnboardingWindow.shared.tryIt = tryIt
            #if DEBUG
            if DebugFlags.setupFirst { director.skip(); DispatchQueue.main.asyncAfter(deadline: .now() + 1) { begin() }; return }
            if let name = DebugFlags.onboardingStep, let target = Step(rawValue: name) {
                director.skip(); step = target; dropAtStep = true
                if DebugFlags.onboardingDefaultShortcut, let chord = ShortcutSettings.shared.defaultShortcut(.correct) { shortcut.seed(chord, phase: .waiting) }
                // After the step's own start, which listens the way the step needs.
                if DebugFlags.onboardingRecording { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { if target == .tryIt { tryIt.change() } else { shortcut.change() } } }
                return
            }
            if DebugFlags.brandReview { director.skip(); return }
            #endif
            if let resume { director.skip(); step = resume; dropAtStep = true; return }
            director.play()
        }
        .onChange(of: step) { _, now in
            if resumable, now != .hello { UserDefaults.standard.set(now.rawValue, forKey: OnboardingWindow.resumeKey) }
        }
        .environment(\.onboardingEffectsVisible, presentation.visible)
        .onDisappear { director.stop(); providers.stop(); shortcut.stop(); accessibility.stop(); tryIt.stop() }
    }

    /// Set up: the drop appears exactly over the finale's own, which hides, then flies to the step.
    private func begin() {
        if reduceMotion {
            dropAtStep = true
            withAnimation(.easeOut(duration: 0.2)) { step = .provider }
            return
        }
        step = .provider
        DispatchQueue.main.async {
            withAnimation(.spring(duration: 0.85 * DebugFlags.brandTransitionScale, bounce: 0.18)) { dropAtStep = true }
        }
    }

    private func companion(in rect: CGRect) -> some View {
        let eyes: (CGSize, Double, Double) = if !dropAtStep { (BrandWordmark.characterLook(director.finaleLook), director.finaleLid, 0) }
            else if step == .shortcut { (shortcut.look, shortcut.lid, shortcut.check) }
            else if step == .accessibility { (accessibility.look, accessibility.lid, accessibility.check) }
            else if step == .home { (home.look, 0, 0) }
            else if providers.showingAPI {
                (CGSize(width: providers.api.enteringKey ? -0.65 : 0, height: providers.api.passed ? 0 : providers.api.enteringKey ? -0.25 : 0.65), providers.api.busy ? 0.25 : providers.api.error == nil ? 0 : 0.55,
                 providers.api.passed ? 1 : 0)
            } else { (providers.look, providers.lid, providers.check) }
        // On the Accessibility step the drop is what gets dragged: it lifts under the pointer and
        // steps aside while the pointer carries it.
        let lifted = step == .accessibility && accessibility.hovering && !accessibility.carried
        let carried = step == .accessibility && accessibility.carried
        return Color.clear.frame(width: rect.width, height: rect.height)
            .glassEffect(.clear, in: .circle)
            .overlay {
                BrandCharacterRim().fill(.white, style: FillStyle(eoFill: true))
                    .opacity(dropAtStep ? 0 : 1)
            }
            .overlay { DashEyes(look: eyes.0, lid: eyes.1, check: eyes.2, ink: .white, halo: .black.opacity(0.35)) }
            .animation(reduceMotion ? nil : .spring(duration: 0.35), value: providers.api.phase)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: providers.api.enteringKey)
            .scaleEffect(carried ? 0.6 : lifted ? 1.08 : 1)
            .opacity(carried ? 0 : 1)
            .shadow(color: .black.opacity(lifted ? 0.25 : 0), radius: 18, y: 10)
            .position(x: rect.midX, y: rect.midY)
            .accessibilityHidden(true)
    }
}

/// Where the setup steps are: a dot each along the bottom, the current one a wider pill.
struct OnboardingProgress: View {
    let steps: Int
    let current: Int
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || DebugFlags.brandReduceMotion }

    var body: some View {
        HStack(spacing: 7) {
            ForEach(0..<steps, id: \.self) { index in
                Capsule().fill(.white.opacity(index == current ? 0.9 : index < current ? 0.5 : 0.25))
                    .frame(width: index == current ? 20 : 7, height: 7)
            }
        }
        .shadow(color: .black.opacity(0.25), radius: 3)
        .animation(reduceMotion ? nil : .spring(duration: 0.45, bounce: 0.2), value: current)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(current + 1) of \(steps)")
    }
}

extension EnvironmentValues {
    @Entry var onboardingEffectsVisible = true
}
