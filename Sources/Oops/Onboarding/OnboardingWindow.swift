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

    func show(turningOn feature: OnboardingFeature? = nil) {
        if window == nil { turningOn = feature }
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
        window = nil; turningOn = nil
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
    typealias Step = OnboardingStep
    let close: () -> Void
    let presentation: WelcomePresentation
    let turningOn: OnboardingFeature?
    /// A first run not finished yet: it remembers its step. Show welcome replays from Hello and remembers nothing.
    private let resumable: Bool
    /// The step an unfinished onboarding left off at, which it reopens at instead of Hello.
    private let resume: Step?
    @State private var director = HelloDirector()
    @State private var features: FeaturesStep
    @State private var speech: OnboardingSpeechModel
    /// The step to come back to once the Provider step, opened from the pill, has set up an OpenAI key.
    @State private var detour: Step?
    @State private var wantsOpenAI = false
    @State private var providers: ProviderStep
    @State private var shortcut: ShortcutStep
    @State private var dictateShortcut: ShortcutStep
    @State private var microphone: MicrophoneStep
    @State private var accessibility = AccessibilityStep()
    @State private var tryIt: TryItStep
    @State private var dictateTry: DictateTryStep
    /// Try it has moved from Fix's beat to the spoken one.
    @State private var speaking = false
    @State private var home: HomeStep
    @State private var step = Step.hello
    /// The companion drop has left Hello's finale for the step's header.
    @State private var dropAtStep = false
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || DebugFlags.brandReduceMotion }

    init(preferences: Preferences?, presentation: WelcomePresentation, turningOn: OnboardingFeature?, close: @escaping () -> Void) {
        self.presentation = presentation; self.turningOn = turningOn
        _features = State(initialValue: FeaturesStep(saves: preferences != nil, only: turningOn))
        let speech = OnboardingSpeechModel(providers: preferences?.providers)
        _speech = State(initialValue: speech)
        _providers = State(initialValue: ProviderStep(preferences: preferences))
        let shortcut = ShortcutStep(saves: preferences != nil)
        _shortcut = State(initialValue: shortcut)
        let dictateShortcut = ShortcutStep(saves: preferences != nil, action: .dictate)
        _dictateShortcut = State(initialValue: dictateShortcut)
        _dictateTry = State(initialValue: DictateTryStep(preferences: preferences, keys: dictateShortcut, speech: speech))
        _microphone = State(initialValue: MicrophoneStep(saves: preferences != nil))
        // Try it's Change records with the Shortcut step's own recorder.
        _tryIt = State(initialValue: TryItStep(preferences: preferences, shortcuts: shortcut))
        _home = State(initialValue: HomeStep(saves: preferences != nil))
        self.close = close
        resumable = preferences != nil && !OnboardingWindow.finished && turningOn == nil
        resume = resumable ? UserDefaults.standard.string(forKey: OnboardingWindow.resumeKey).flatMap(Step.init(rawValue:)) : nil
    }

    /// The steps after Hello, which the dots count: the ones the chosen features need.
    private var setup: [Step] { turningOn == nil ? Step.setup(for: features.chosen, choice: DebugFlags.dictation) : [.shortcut, .tryIt] }

    /// Whether the steps cover `feature`: all of today's flow is Fix's, and the choice decides once it is asked.
    private func asksFor(_ feature: OnboardingFeature) -> Bool {
        if let turningOn { return feature == turningOn }
        return setup.contains(.features) ? features.chosen.contains(feature) : feature == .fix
    }

    /// Fix's try is done: its reply is sent, and Léa's next question waits for a spoken answer.
    private func speak() {
        dictateTry.earlier = tryIt.conversation.messages + [(tryIt.sentText, true)]
        // The replay's thread is Hello's cinema, the live one dinner plans.
        if !tryIt.isLive { dictateTry.question = "want me to grab you a drink?" }
        withAnimation(.easeInOut(duration: 0.45)) { speaking = true }
    }

    private func advance() {
        // The short run a new-feature card opens ends with its last step.
        guard let index = setup.firstIndex(of: step), index + 1 < setup.count else { return turningOn == nil ? () : close() }
        withAnimation(.easeInOut(duration: 0.45)) { step = setup[index + 1] }
    }

    var body: some View {
        // The first step waits for Hello's finale to clear.
        let entrance = AnyTransition.opacity.animation(.easeOut(duration: 0.45).delay(0.3))
        ZStack {
            HelloScene(director: director, handedOff: step != .hello, visible: presentation.visible) { begin() }
                .disabled(step != .hello)
                // Behind a setup step Hello is wallpaper: VoiceOver reads the step, not Hello's drops.
                .accessibilityHidden(step != .hello)
            switch step {
            case .hello: EmptyView()
            case .features:
                FeaturesStepView(step: features) {
                    features.commit()
                    if features.chosen.contains(.dictate) { speech.start() }
                    advance()
                }
                .transition(entrance)
            case .provider:
                ProviderStepView(step: providers, next: leaveProvider).transition(setup.first == .provider ? entrance : .opacity)
            case .shortcut:
                ShortcutStepView(fix: asksFor(.fix) ? shortcut : nil, dictate: asksFor(.dictate) ? dictateShortcut : nil,
                                 microphone: microphone, next: advance)
                    .transition(.opacity)
            case .accessibility:
                AccessibilityStepView(step: accessibility, next: advance).transition(.opacity)
            case .tryIt:
                if speaking || !asksFor(.fix) {
                    DictateTryView(step: dictateTry, fix: tryIt, next: advance).transition(.opacity)
                } else {
                    TryItStepView(step: tryIt, next: asksFor(.dictate) ? speak : advance).transition(.opacity)
                }
            case .home:
                HomeStepView(step: home).transition(.opacity)
            }
            if step != .hello {
                OnboardingProgress(steps: setup.count, current: setup.firstIndex(of: step) ?? 0)
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
        .overlay(alignment: .topTrailing) {
            if speech.started, !speech.dismissed, step != .hello, step != .home, features.chosen.contains(.dictate) {
                SpeechModelPill(speech: speech, useOpenAIKey: useOpenAIKey)
                    .padding(.top, 16).padding(.trailing, 20)
                    .transition(.scale(scale: 0.7, anchor: .trailing).combined(with: .opacity))
                    .environment(\.colorScheme, .dark)
            }
        }
        .animation(reduceMotion ? nil : .spring(duration: 0.5, bounce: 0.3), value: speech.started && !speech.dismissed)
        .overlayPreferenceValue(OnboardingDropKey.self) { anchors in
            GeometryReader { proxy in
                // Try it has the real drop, over its composer.
                if step != .hello, step != .tryIt, let anchor = anchors[dropAtStep ? "step" : "finale"] { companion(in: proxy[anchor]) }
            }
            .allowsHitTesting(false)
        }
        .onAppear {
            OnboardingWindow.shared.tryIt = tryIt
            if turningOn == .dictate {
                director.skip(); step = .shortcut; dropAtStep = true
                speech.start()
                return
            }
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
            if let resume {
                director.skip(); step = resume; dropAtStep = true
                // A relaunch mid-way picks the download up where it stopped.
                if resume != .features, setup.contains(.features), features.chosen.contains(.dictate) { speech.start() }
                return
            }
            director.play()
        }
        .onChange(of: step) { _, now in
            if resumable, now != .hello { UserDefaults.standard.set(now.rawValue, forKey: OnboardingWindow.resumeKey) }
        }
        .environment(\.onboardingEffectsVisible, presentation.visible)
        .onDisappear { director.stop(); providers.stop(); shortcut.stop(); dictateShortcut.stop(); accessibility.stop(); tryIt.stop(); dictateTry.stop() }
    }

    /// The pill's "Use an OpenAI key": the Provider step's own API setup, opened on OpenAI, from whichever step this is.
    private func useOpenAIKey() {
        speech.pause()
        wantsOpenAI = true
        if step != .provider { detour = step; withAnimation(.easeInOut(duration: 0.45)) { step = .provider } }
        providers.openAPI(preset: ProviderPreset(id: "openai"))
    }

    /// Past the Provider step: a key set up for dictation makes OpenAI its model; without one the download resumes.
    private func leaveProvider() {
        if wantsOpenAI {
            wantsOpenAI = false
            if let reference = OnboardingWindow.shared.preferences?.providers.openAIDictateReference { speech.useOpenAI(reference) } else { speech.resume() }
        }
        guard let back = detour else { return advance() }
        detour = nil
        withAnimation(.easeInOut(duration: 0.45)) { step = back }
    }

    /// Set up: the drop appears exactly over the finale's own, which hides, then flies to the step.
    private func begin() {
        if reduceMotion {
            dropAtStep = true
            withAnimation(.easeOut(duration: 0.2)) { step = setup[0] }
            return
        }
        step = setup[0]
        DispatchQueue.main.async {
            withAnimation(.spring(duration: 0.85 * DebugFlags.brandTransitionScale, bounce: 0.18)) { dropAtStep = true }
        }
    }

    /// The eyes follow whichever recorder is on stage: Dictate's once Fix's is in, or alone.
    private var shortcutEyes: (CGSize, Double, Double) {
        let keys = asksFor(.dictate) && (!asksFor(.fix) || shortcut.phase == .accepted) ? dictateShortcut : shortcut
        let refused = microphone.state == .refused
        return (keys.look, refused ? 0.55 : keys.lid, refused ? 0 : keys.check)
    }

    private func companion(in rect: CGRect) -> some View {
        let eyes: (CGSize, Double, Double) = if !dropAtStep { (BrandWordmark.characterLook(director.finaleLook), director.finaleLid, 0) }
            else if step == .shortcut { shortcutEyes }
            else if step == .accessibility { (accessibility.look, accessibility.lid, accessibility.check) }
            else if step == .home { (home.look, 0, 0) }
            else if step == .features { (features.look, 0, 0) }
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
