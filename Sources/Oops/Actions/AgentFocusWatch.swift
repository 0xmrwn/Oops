import AppKit

/// Reports whether the person is in an agent run's field, as it changes. Leaving the app counts at once; while the
/// app is in front, the field is checked twice a second off the main thread, and leaving it takes two misses in a row,
/// so a menu or a popover opening for a moment doesn't send the drop away.
@MainActor final class AgentFocusWatch {
    /// Whether that field has focus now; called off the main thread.
    private let holds: @Sendable (EditorSnapshot) -> Bool
    var changed: (Bool) -> Void = { _ in }
    private var snapshot: EditorSnapshot?
    private var inside = true, misses = 0, sampling = false
    private var timer: Timer?
    private var observer: NSObjectProtocol?

    init(holds: @escaping @Sendable (EditorSnapshot) -> Bool) { self.holds = holds }

    /// Starts watching the field `snapshot` read, with the person in it.
    func start(_ snapshot: EditorSnapshot) {
        stop()
        self.snapshot = snapshot
        inside = true; misses = 0
        let pid = snapshot.hostPID ?? snapshot.pid
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil,
                                                                     queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let returned = app?.processIdentifier == pid
            MainActor.assumeIsolated {
                guard let self else { return }
                if returned { self.sample() } else { self.report(false) }
            }
        }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.sample() } }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate(); timer = nil
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil; snapshot = nil
    }

    private func sample() {
        guard let snapshot, !sampling else { return }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == snapshot.hostPID ?? snapshot.pid else { return report(false) }
        sampling = true
        let holds = holds
        Task { [weak self] in
            let held = await Task.detached(priority: .utility) { holds(snapshot) }.value
            guard let self else { return }
            self.sampling = false
            // A run that ended while the check was out has nothing left to tell.
            guard self.snapshot != nil else { return }
            if held { self.misses = 0; self.report(true) } else {
                self.misses += 1
                if self.misses >= 2 { self.report(false) }
            }
        }
    }

    private func report(_ now: Bool) {
        if !now { misses = 0 }
        guard now != inside else { return }
        inside = now
        changed(now)
    }
}
