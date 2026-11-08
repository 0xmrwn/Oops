import AppKit

/// Quits Oops and opens this same copy again once the old process has gone.
@MainActor enum Relaunch {
    static func now() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let waiter = Process()
        waiter.executableURL = URL(fileURLWithPath: "/bin/sh")
        waiter.arguments = ["-c", "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.1; done; /usr/bin/open \"$0\"",
                            Bundle.main.bundlePath]
        do { try waiter.run() } catch { return }
        NSApp.terminate(nil)
    }
}
