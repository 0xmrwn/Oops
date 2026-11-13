import ApplicationServices
import AppKit
import OopsCore

/// Wires the parts together: the hotkeys and the menu bar start corrections, the session runs them,
/// Settings configures them.
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let preferences = Preferences()
    let testEditor = TestEditorModel()
    /// The drop and the flash over the draft, which one feature holds at a time.
    let drop = DropOwner()
    private(set) lazy var session = CorrectionSession(preferences: preferences, testEditor: testEditor, drop: drop)
    private(set) lazy var settings = SettingsWindow(preferences: preferences, testEditor: testEditor, session: session)
    private(set) var menuBar: MenuBar?
    private let shortcuts = HyperShortcuts()
    /// Only while dictation is switched on (`DebugFlags.dictation`).
    private(set) var dictation: DictationSession?

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settings.show()
        return false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        CommandKeys.shared.observe()
        // A previous run that crashed mid-correction may have left a Chromium app's switch on.
        session.editor.switches.restoreAll()
        quitOnSIGTERM()
        configureMainMenu()
        menuBar = MenuBar(preferences: preferences, session: session,
                          openSettings: { [weak self] in self?.settings.show() }, quit: { [weak self] in self?.quit() })
        session.openSettings = { [weak self] in self?.settings.show() }
        session.retryInTry = { [weak self] in self?.correctInTry() }
        session.activeTry = { [weak self] in
            guard let self else { return nil }
            return self.settings.tryIsActive ? self.testEditor : OnboardingWindow.shared.activeTry
        }
        testEditor.onCorrect = { [weak self] in self?.correctInTry() }
        testEditor.onRestore = { [weak self] in self?.restoreInTry() }
        testEditor.onOpenSettings = { [weak self] in self?.preferences.providers.wantsProvidersPage = true }
        dictation = makeDictation()
        // Fix runs on its press; its release ends nothing. Dictate hears both, at the instants they happened.
        shortcuts.invoke = { [weak self] action, phase, instant in
            switch (action, phase) {
            case (.correct, .pressed): self?.session.correct()
            case (.correct, .released): break
            case (.dictate, _): self?.dictation?.shortcut(phase, at: instant.capture, now: instant.clock)
            case (.dictateAndCleanUp, _): self?.dictation?.shortcut(phase, at: instant.capture, now: instant.clock, cleanUp: true)
            }
        }
        shortcuts.registrationFailed = { [weak self] message in self?.preferences.status = message }
        do { try shortcuts.register() } catch { preferences.status = error.localizedDescription }
        warmUpDictation()
        // Onboarding asks for Accessibility in its own step; closed without it (skipped), Settings asks. Updates
        // wait for the first onboarding to end too, so nothing goes out before the person has chosen anything.
        OnboardingWindow.shared.onClose = { [weak self] in
            Updates.shared.start()
            if !AccessibilityPermission.granted { self?.settings.show() }
        }
        OnboardingWindow.shared.preferences = preferences
        OnboardingWindow.shared.menuBar = menuBar
        if !OnboardingWindow.finished {
            OnboardingWindow.shared.show()
        } else {
            Updates.shared.start()
            if !AccessibilityPermission.granted { settings.show() }
        }
        #if DEBUG
        installDebugHooks()
        #endif
    }

    /// Nothing Oops started outlives it: Claude Code processes and Chromium accessibility switches.
    func applicationWillTerminate(_ notification: Notification) {
        ClaudeCode.endRunningProcesses()
        ClaudeCodeSignIn.cancel()
        session.editor.settle(timeout: 1)
        session.editor.switches.restoreAll()
    }

    /// `pkill` and logout send SIGTERM, which would skip `applicationWillTerminate`: quit properly instead.
    private func quitOnSIGTERM() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        sigterm = source
    }
    private var sigterm: DispatchSourceSignal?

    /// Try's Fix and Restore buttons act on Try's own draft.
    func correctInTry() { Task { await settings.focusTry(); session.correct(inTryOnly: true) } }
    func restoreInTry() { Task { await settings.focusTry(); session.revert() } }

    /// NSTextView's standard Command-V and undo routing depends on an Edit menu, even in this accessory
    /// app's own window.
    private func configureMainMenu() {
        let main = NSMenu()
        let appMenu = NSMenu(title: "Oops")
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        appMenu.addItem(withTitle: "Quit Oops", action: #selector(quitApp), keyEquivalent: "q").target = self
        main.addItem(withTitle: "Oops", action: nil, keyEquivalent: "").submenu = appMenu
        main.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = AppMenus.edit()
        NSApp.mainMenu = main
    }

    @objc private func openSettings() { settings.show() }
    @objc private func quitApp() { quit() }
    private func quit() { session.cancel(); shortcuts.unregister(); NSApp.terminate(nil) }
}

@main enum OopsMain {
    @MainActor static func main() {
        signal(SIGPIPE, SIG_IGN)
        KeychainPrompts.disallow()
        // Tooltips carry the explanations Settings no longer prints (the ⓘ marks): half a second,
        // sooner than AppKit's default but not on a pass of the pointer.
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 500])
        let app = NSApplication.shared
        #if DEBUG
        if let directory = DebugFlags.brandSnapshots { BrandSnapshots.render(to: directory); exit(0) }
        if let directory = DebugFlags.helloSnapshots { HelloSnapshots.render(to: directory); exit(0) }
        if let directory = DebugFlags.gradientSnapshots { GradientSnapshots.render(to: directory); exit(0) }
        if let directory = DebugFlags.setupSnapshots { SetupSnapshots.render(to: directory); exit(0) }
        if let directory = DebugFlags.settingsSnapshots { SettingsSnapshots.render(to: directory); exit(0) }
        if let directory = DebugFlags.dictationVisualizerSnapshots { DictationVisualizerSnapshots.render(to: directory); exit(0) }
        if DebugFlags.dictationDropLab {
            let lab = DictationDropLab()
            DispatchQueue.main.async { lab.show() }
            withExtendedLifetime(lab) { app.run() }; return
        }
        if DebugFlags.brandReview, DebugFlags.capsuleReview {
            let review = BrandCapsuleReview()
            DispatchQueue.main.async { review.show() }
            withExtendedLifetime(review) { app.run() }; return
        }
        if DebugFlags.brandReview, DebugFlags.iconReview {
            let review = BrandIconReview()
            DispatchQueue.main.async { review.show() }
            withExtendedLifetime(review) { app.run() }; return
        }
        if DebugFlags.brandReview, DebugFlags.openSettings {
            let preferences = Preferences(), editor = TestEditorModel()
            // Only a state preview: the isolated review never edits text or calls a provider.
            editor.onCorrect = { [weak editor] in
                guard let editor else { return }
                if editor.isWorking { editor.cancelled(); editor.busy = false; return }
                editor.began(); editor.busy = true
                Task {
                    try? await Task.sleep(for: .seconds(1.8))
                    guard editor.isWorking else { return }
                    editor.busy = false; editor.alreadyClear(seconds: 1.8)
                }
            }
            let settings = SettingsWindow(preferences: preferences, testEditor: editor, session: nil)
            DispatchQueue.main.async { settings.show() }
            withExtendedLifetime(settings) { app.run() }; return
        }
        // Onboarding alone, for a look without a second full Oops (hotkeys, menu bar, switch recovery).
        if DebugFlags.helloOnly {
            AppMenus.installReview()
            OnboardingWindow.shared.onClose = { NSApp.terminate(nil) }
            DispatchQueue.main.async { OnboardingWindow.shared.show() }
            app.run(); return
        }
        #endif
        // The update test's copy runs the updater alone: no shortcuts, menu bar, Keychain or windows.
        if Updates.isHarness { Updates.shared.runHarness(); app.run(); return }
        let delegate = AppDelegate(); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

extension NSApplication {
    /// Settings and onboarding make Oops a regular app (Dock, Command-Tab) while they're open; it goes
    /// back to the menu bar only when the last of them closes, not when either one does.
    /// A regular app (Dock icon, Command-Tab) while a window is open. The Dock reloads the bundle's icon, light
    /// whatever the theme, each time the app joins it, so the themed one is set again after.
    func enterDock() {
        setActivationPolicy(.regular)
        DockIcon.refresh()
    }

    func leaveDockUnlessOtherWindows(than closing: NSWindow) {
        guard !windows.contains(where: { $0 !== closing && $0.isVisible && $0.styleMask.contains(.titled) }) else { return }
        setActivationPolicy(.accessory)
        DockIcon.releaseWhenAccessory()
    }
}
