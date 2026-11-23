import AppKit

/// Reports whether the person is in an agent run's field, as it changes. Leaving the app counts at once; while the
/// app is in front, the field is checked twice a second off the main thread, and leaving it takes two misses in a row,
/// so a menu or a popover opening for a moment doesn't send the drop away. While the ready drop waits at the caret it
/// also tells when the draft changes, and while the person is away whether the app in front is in full screen.
@MainActor final class AgentFocusWatch {
    /// Whether that field has focus now; whether its draft still reads as it was read; whether the app with a pid
    /// shows its window in native full screen. Called off the main thread.
    private let holds: @Sendable (EditorSnapshot) -> Bool
    private let unchanged: @Sendable (EditorSnapshot) -> Bool
    private let fullScreen: @Sendable (pid_t) -> Bool
    var changed: (Bool) -> Void = { _ in }
    /// The draft changed while `watchesDraft`: told once, and the draft is watched no more until it is set again.
    var edited: () -> Void = {}
    /// Whether the app in front is in full screen, as it changes while `watchesScreen`.
    var screenChanged: (Bool) -> Void = { _ in }
    /// Each tick, for what follows the screen the person works on.
    var ticked: () -> Void = {}
    var watchesDraft = false
    var watchesScreen = false {
        didSet { if watchesScreen, !oldValue { sampleScreen() } }
    }
    private var snapshot: EditorSnapshot?
    private var inside = true, misses = 0, sampling = false, screenSampling = false
    /// Full screen as last told; nil until the first sample, which is always told.
    private var full: Bool?
    private var timer: Timer?
    private var observer: NSObjectProtocol?

    init(holds: @escaping @Sendable (EditorSnapshot) -> Bool, unchanged: @escaping @Sendable (EditorSnapshot) -> Bool = { _ in true },
         fullScreen: @escaping @Sendable (pid_t) -> Bool = AgentFocusWatch.showsFullScreen) {
        self.holds = holds; self.unchanged = unchanged; self.fullScreen = fullScreen
    }

    /// Starts watching the field `snapshot` read, with the person in it or, for a ready result, `inside` it or not.
    func start(_ snapshot: EditorSnapshot, inside: Bool = true) {
        stop()
        self.snapshot = snapshot
        self.inside = inside; misses = 0; full = nil
        let pid = snapshot.hostPID ?? snapshot.pid
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil,
                                                                     queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let returned = app?.processIdentifier == pid
            MainActor.assumeIsolated {
                guard let self else { return }
                if returned { self.sample() } else { self.report(false) }
                self.sampleScreen()
            }
        }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.sample(); self.sampleScreen(); self.ticked()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate(); timer = nil
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil; snapshot = nil; watchesDraft = false; watchesScreen = false
    }

    private func sample() {
        guard let snapshot, !sampling else { return }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == snapshot.hostPID ?? snapshot.pid else { return report(false) }
        sampling = true
        let holds = holds, unchanged = unchanged, draft = watchesDraft
        Task { [weak self] in
            let (held, same) = await Task.detached(priority: .utility) {
                let held = holds(snapshot)
                return (held, !draft || !held || unchanged(snapshot))
            }.value
            guard let self else { return }
            self.sampling = false
            // A run that ended while the check was out has nothing left to tell.
            guard self.snapshot != nil else { return }
            if held {
                self.misses = 0; self.report(true)
                if !same, self.watchesDraft { self.watchesDraft = false; self.edited() }
            } else {
                self.misses += 1
                if self.misses >= 2 { self.report(false) }
            }
        }
    }

    private func sampleScreen() {
        guard snapshot != nil, watchesScreen, !screenSampling, let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
        screenSampling = true
        let fullScreen = fullScreen
        Task { [weak self] in
            let now = await Task.detached(priority: .utility) { fullScreen(pid) }.value
            guard let self else { return }
            self.screenSampling = false
            guard self.snapshot != nil, self.watchesScreen, now != self.full else { return }
            self.full = now
            self.screenChanged(now)
        }
    }

    private func report(_ now: Bool) {
        if !now { misses = 0 }
        guard now != inside else { return }
        inside = now
        changed(now)
    }

    /// Whether the focused window of the app with `pid` is in native full screen, where the menu bar and the parked
    /// pill have no room of their own.
    nonisolated static func showsFullScreen(_ pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success, let window,
              CFGetTypeID(window) == AXUIElementGetTypeID() else { return false }
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(window as! AXUIElement, "AXFullScreen" as CFString, &value)
        return value as? Bool == true
    }
}
