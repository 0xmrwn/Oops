import AppKit

/// Sign-in stays in Claude Code's own flow: `claude auth login` opens Anthropic's page in the browser
/// and hears back on localhost, and Oops never sees the credentials. The CLI is an interactive
/// terminal app, so it runs out of sight in a pseudo-terminal (`script`) instead of a Terminal
/// window; `finished` hears when it ends, signed in or not, and it gives up after ten minutes.
/// Settings and onboarding share it.
@MainActor enum ClaudeCodeSignIn {
    static let install = URL(string: "https://code.claude.com/docs/en/setup")!
    private static var running: Process?
    /// Held open: `script` would end the session at the end of its input.
    private static var input: Pipe?

    /// False when the sign-in couldn't start. One at a time: a second call while one runs only reports it.
    @discardableResult static func open(_ executable: URL, finished: @escaping @MainActor () -> Void = {}) -> Bool {
        if running?.isRunning == true { return true }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = ["-q", "/dev/null", executable.path, "auth", "login"]
        let pipe = Pipe()
        process.standardInput = pipe
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in
            Task { @MainActor in
                running = nil; input = nil
                finished()
            }
        }
        do { try process.run() } catch { return false }
        running = process; input = pipe
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(600))
            if running === process { process.terminate() }
        }
        return true
    }

    /// Ends a sign-in still waiting for the browser (quitting Oops, leaving onboarding).
    static func cancel() { running?.terminate() }
}
