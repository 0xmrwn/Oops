#if DEBUG
import AppKit
import OSLog

/// Debug builds only: launch-argument previews, lab triggers and the perf harness (see DebugFlags).
@MainActor extension AppDelegate {
    func installDebugHooks() {
        if DebugFlags.openSettings { settings.show() }
        if DebugFlags.openWelcome { OnboardingWindow.shared.show() }
        if DebugFlags.openTry { settings.showTry() }
        if DebugFlags.previewCapsule { session.preview() }
        if DebugFlags.previewWorking { session.capsule.show(.working, label: "Fixing…") }
        if DebugFlags.previewFailure { session.previewFailure() }
        if DebugFlags.previewPending { session.previewPending() }
        if let surface = DebugFlags.perfHarness { runPerfHarness(surface) }
        if DebugFlags.labTriggers { observeLabTriggers() }
    }

    /// Lets a lab run start a placement preview, a probe, or a real correction without clicking Oops
    /// (which would take focus from the editor). A correction only ever reaches Try's draft or a lab
    /// window in front, never another app's draft, whatever has focus.
    private func observeLabTriggers() {
        let center = DistributedNotificationCenter.default()
        func on(_ name: String, _ action: @escaping @MainActor ([String: String]) -> Void) {
            center.addObserver(forName: .init("dev.0xmrwn.oops." + name), object: nil, queue: .main) { note in
                let info = note.userInfo as? [String: String] ?? [:]
                MainActor.assumeIsolated { action(info) }
            }
        }
        on("preview-placement") { [weak self] _ in
            guard let self else { return }
            Task { self.preferences.status = await self.session.previewPlacement() }
        }
        on("correct") { [weak self] _ in
            // Settings' Try page, or onboarding's Try it while it is the window in front.
            if self?.testEditor.presented == true { self?.correctInTry() } else if OnboardingWindow.shared.activeTry != nil { self?.session.correct() }
            else { OnboardingWindow.shared.tryIt?.playReplay() }
        }
        on("restore") { [weak self] _ in if self?.testEditor.presented == true { self?.restoreInTry() } }
        on("menu") { [weak self] _ in self?.menuBar?.open() }
        on("correct-lab") { [weak self] _ in if Self.labIsInFront() { self?.session.correct() } }
        on("restore-lab") { [weak self] _ in if Self.labIsInFront() { self?.session.revert() } }
        // Compatibility runs: a scratch draft in the app the trigger names, and only while it is in front.
        on("app") { [weak self] info in
            guard let self, let bundle = info["bundle"], let action = info["action"] else { return }
            let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundle
            switch action {
            case "correct" where front: self.session.correct()
            case "restore" where front: self.session.revert()
            default: AppProbe.run(action, bundle: bundle, text: info["text"],
                                  placement: self.session.capsule.placement.map(\.strategy.rawValue), editor: self.session.editor)
            }
        }
        // Geometry only, never text, like Debug tools → Probe: `mode` is plain, manual or enhanced.
        on("probe") { [weak self] info in
            let mode = PlacementProbe.Mode(rawValue: info["mode"] ?? "") ?? .plain
            Task { self?.preferences.status = await PlacementProbe.record(mode: mode) }
        }
    }

    /// Whether the focused element's window is a lab (fixtures/composer-lab, fixtures/native-lab), by
    /// title. Chromium's focused-window attribute is less reliable, and its tree can be dormant until a
    /// client reads the app: wake it and retry, like capture.
    private static func labIsInFront() -> Bool {
        let log = Logger(subsystem: "dev.0xmrwn.oops", category: "Correction")
        var focused: CFTypeRef?, window: CFTypeRef?, title: CFTypeRef?
        let system = AXUIElementCreateSystemWide()
        for attempt in 0..<4 {
            if AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success { break }
            if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier {
                let app = AXUIElementCreateApplication(pid)
                for name in [kAXRoleAttribute, kAXWindowsAttribute, kAXChildrenAttribute] {
                    var value: CFTypeRef?; _ = AXUIElementCopyAttributeValue(app, name as CFString, &value)
                }
            }
            Thread.sleep(forTimeInterval: 0.3 * Double(attempt + 1))
        }
        guard let focused, CFGetTypeID(focused) == AXUIElementGetTypeID(),
              AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXWindowAttribute as CFString, &window) == .success, let window,
              CFGetTypeID(window) == AXUIElementGetTypeID() else { log.notice("lab_trigger no focused window"); return false }
        let status = AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title)
        let inFront = ["oops composer lab", "oops native lab"].contains { (title as? String)?.hasPrefix($0) == true }
        log.notice("lab_trigger title_status=\(status.rawValue, privacy: .public) title_length=\((title as? String)?.count ?? -1, privacy: .public) in_front=\(inFront, privacy: .public)")
        return inFront
    }

    /// Drives one surface on a loop with windows ordered front but Oops never activated, so
    /// `fixtures/perf/run.sh` can profile it without taking focus from whoever is working.
    private func runPerfHarness(_ surface: String) {
        switch surface {
        case "settings": settings.show() // The view cycles its tabs under the harness.
        case "capsule":
            Task { [weak self] in
                while let self, !Task.isCancelled { self.session.preview(); try? await Task.sleep(for: .seconds(4.5)) }
            }
        case "editor":
            settings.showTry()
            Task { [weak self] in
                var index = 0
                while let self, !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(0.8)); self.testEditor.began()
                    try? await Task.sleep(for: .seconds(1.6)); self.testEditor.alreadyClear(seconds: 1.6)
                    try? await Task.sleep(for: .seconds(1.2))
                    index = (index + 1) % SampleDraft.allCases.count
                    self.testEditor.load(SampleDraft.allCases[index])
                }
            }
        default: break
        }
        // After a one-second settle, measure frame pacing, write the summary and quit, so
        // fixtures/perf/run.sh needs no system-wide trace.
        guard let report = DebugFlags.perfReport else { return }
        let seconds = max(DebugFlags.perfSeconds, 3)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            let pacer = FramePacer(); pacer.begin(on: NSScreen.main ?? NSScreen.screens[0])
            try? await Task.sleep(for: .seconds(seconds))
            pacer.finish(writingTo: report)
            NSApp.terminate(nil)
        }
    }
}
#endif
