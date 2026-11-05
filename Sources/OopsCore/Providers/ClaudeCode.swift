import Foundation
import Synchronization

/// Claude through the installed, unmodified Claude Code CLI. Sign-in, refresh and billing stay in
/// Claude Code (Anthropic's terms for running Claude Code inside products): oops never reads, stores
/// or forwards its credentials, and adds or strips no authentication environment.
public enum ClaudeCode {
    public struct Model: Equatable, Sendable, Identifiable {
        /// What `--model` takes: an alias (`haiku`) that follows new releases, or a pinned full name.
        public let value: String
        public let name: String
        public let resolved: String
        public let efforts: [String]
        public let fast: Bool
        /// Anthropic's one-line description, as Claude Code's model picker shows it.
        public var summary: String?
        public var id: String { value }
        /// Aliases track the latest release; full names are older, pinned models.
        public var isAlias: Bool { ClaudeCode.isAlias(value) }
    }

    public static func isAlias(_ value: String) -> Bool { !value.hasPrefix("claude-") }

    public struct Account: Equatable, Sendable {
        public let email: String?, organization: String?, plan: String?
        public init(email: String?, organization: String?, plan: String?) { self.email = email; self.organization = organization; self.plan = plan }
    }

    public enum Status: Equatable, Sendable {
        case notInstalled, signedOut
        case signedIn(Account)
    }

    // MARK: Arguments

    /// Customisations, tools, MCP and session files off; oops's prompt replaces Claude Code's; native
    /// schema output; streamed events so the result is read without waiting for the process to exit.
    static let common = ["--safe-mode", "-p", "--tools", "", "--strict-mcp-config", "--permission-mode", "dontAsk",
                         "--no-session-persistence", "--output-format", "stream-json", "--verbose"]

    public static func correctionArguments(model: String, effort: String?) -> [String] {
        var arguments = common + ["--model", model]
        if let effort { arguments += ["--effort", effort] }
        return arguments + ["--system-prompt", CorrectionPolicy.instructions, "--json-schema", schema]
    }

    static let catalogArguments = common + ["--input-format", "stream-json"]
    static let initialize = #"{"type":"control_request","request_id":"oops-catalog","request":{"subtype":"initialize"}}"#

    static var schema: String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: CorrectionPolicy.schema, options: [.sortedKeys])) ?? Data(), as: UTF8.self)
    }

    // MARK: Decoding

    /// `claude auth status` (JSON on stdout).
    static func decodeStatus(_ data: Data) -> Status {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["loggedIn"] as? Bool == true else { return .signedOut }
        return .signedIn(Account(email: text(object["email"]), organization: text(object["orgName"]), plan: nil))
    }

    /// The `initialize` control response: the account's live model list and plan name.
    static func decodeCatalog(_ object: [String: Any]) throws -> (models: [Model], account: Account?) {
        guard let response = (object["response"] as? [String: Any])?["response"] as? [String: Any],
              let list = response["models"] as? [[String: Any]] else {
            throw CorrectionError.message("Claude Code returned an unexpected model list.")
        }
        // "default" repeats the recommended model under another name.
        let models = list.compactMap { entry -> Model? in
            guard let value = text(entry["value"]), value != "default", let name = text(entry["displayName"]) else { return nil }
            return Model(value: value, name: name, resolved: text(entry["resolvedModel"]) ?? value,
                         efforts: (entry["supportedEffortLevels"] as? [String]) ?? [],
                         fast: entry["supportsFastMode"] as? Bool ?? false, summary: text(entry["description"], limit: 400))
        }
        let account = (response["account"] as? [String: Any]).map {
            Account(email: text($0["email"]), organization: text($0["organization"]), plan: text($0["subscriptionType"]))
        }
        return (models, account)
    }

    /// The final `result` event: the schema object as JSON text, or a short reason it failed.
    public static func decodeResult(_ object: [String: Any]) throws -> String {
        if object["is_error"] as? Bool == true || object["subtype"] as? String != "success" {
            throw failure(status: object["api_error_status"] as? Int, detail: text(object["result"], limit: 2_000) ?? "")
        }
        guard let structured = object["structured_output"] as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: structured) else {
            throw CorrectionError.message("Claude didn’t return a correction. Nothing replaced.")
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func failure(status: Int?, detail: String) -> CorrectionError {
        let lower = detail.lowercased()
        if status == 401 || status == 403 || lower.contains("/login") || lower.contains("not logged in") {
            return .failure(.signIn, "Claude Code is signed out. Sign in from Settings → Providers.")
        }
        if status == 429 || lower.contains("usage limit") || lower.contains("rate limit") {
            return .failure(.limit, "Claude usage limit reached. Manage usage at claude.ai/settings/usage.")
        }
        return .message("Claude couldn’t correct this text. Try again.")
    }

    private static func text(_ value: Any?, limit: Int = 200) -> String? {
        guard let value = value as? String, !value.trimmingCharacters(in: .whitespaces).isEmpty, value.count <= limit else { return nil }
        return value
    }
}

// MARK: - Runtime

/// Where the CLI lives. A GUI app's PATH is minimal, so the usual install locations come first and
/// the login shell is asked once as a fallback.
public struct ClaudeCodeRuntime: Sendable, Equatable {
    public let executable: URL
    /// An empty folder the CLI runs in, so no project files, git status or memory get attached.
    public let directory: URL

    public init(executable: URL, directory: URL) { self.executable = executable; self.directory = directory }

    /// `askShell` also asks the login shell, which can take seconds: never on the main thread.
    public static func locate(directory: URL, askShell: Bool = true) -> ClaudeCodeRuntime? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        let found = candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? (askShell ? loginShellPath() : nil)
        guard let found else { return nil }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return ClaudeCodeRuntime(executable: URL(fileURLWithPath: found), directory: directory)
    }

    /// `command -v claude` in a login shell, given three seconds. Output goes to a file, so a profile
    /// that leaves a background job holding stdout can't keep the read open.
    private static func loginShellPath() -> String? {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("oops-claude-path-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: output.path, contents: nil), let handle = try? FileHandle(forWritingTo: output) else { return nil }
        defer { try? handle.close(); try? FileManager.default.removeItem(at: output) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v claude"]
        process.standardOutput = handle; process.standardError = FileHandle.nullDevice; process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning, Date() < deadline { usleep(20_000) }
        guard !process.isRunning else { ClaudeProcess.end(process); return nil }
        let path = (try? String(contentsOf: output, encoding: .utf8))?
            .split(separator: "\n").last.map { $0.trimmingCharacters(in: .whitespaces) }
        return path.flatMap { $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil }
    }

    private static let slow = CorrectionError.message("Claude Code didn’t respond. Check again.")

    /// `claude auth status` alone, the cheap sign-in check: no model list. Same 15 s limit as `connect()`.
    public func status() async throws -> ClaudeCode.Status {
        let auth = try ClaudeProcess(self, arguments: ["auth", "status"])
        defer { auth.terminate() }
        auth.finishInput()
        return ClaudeCode.decodeStatus(try await withDeadline(.seconds(15), orThrow: Self.slow) { await auth.readAll(limit: 64_000) })
    }

    /// Sign-in state, plan and the live model list. Not on the correction path. Each step has a time
    /// limit and ends its process however it finishes, so a stalled CLI can't hold the check open.
    public func connect() async throws -> (status: ClaudeCode.Status, models: [ClaudeCode.Model]) {
        let slow = Self.slow
        let status = try await status()
        guard case .signedIn(let basic) = status else { return (status, []) }
        let catalog = try ClaudeProcess(self, arguments: ClaudeCode.catalogArguments)
        defer { catalog.terminate() }
        catalog.finishInput(ClaudeCode.initialize + "\n")
        let line = try await withDeadline(.seconds(30), orThrow: slow) { try await catalog.firstEvent(ofType: "control_response") }
        let (models, account) = try ClaudeCode.decodeCatalog(ClaudeProcess.object(line))
        let merged = ClaudeCode.Account(email: account?.email ?? basic.email,
                                        organization: account?.organization ?? basic.organization, plan: account?.plan)
        return (.signedIn(merged), models)
    }
}

// MARK: - Backend

/// One fresh process per correction, so drafts never share a conversation. It starts when the
/// shortcut is pressed (`prepare`), while the draft is read, hiding ~0.2 s of startup; Claude Code
/// gives up on an empty stdin after 3 s, so an unused one is ended at 2.5 s and nothing waits idle.
/// The answer is taken from the `result` event, not process exit, saving ~0.9 s of shutdown.
public actor ClaudeCodeBackend: CorrectionBackend {
    public let runtime: ClaudeCodeRuntime
    public let model: String
    public let effort: String?
    private var spare: ClaudeProcess?

    public init(runtime: ClaudeCodeRuntime, model: String, effort: String?) {
        self.runtime = runtime; self.model = model; self.effort = effort
    }

    deinit { spare?.terminate() }

    public func prepare() {
        if let spare, spare.isRunning { return }
        guard let process = try? ClaudeProcess(runtime, arguments: ClaudeCode.correctionArguments(model: model, effort: effort)) else { return }
        spare = process
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(2500))
            await self?.drop(process)
        }
    }

    public func complete(_ text: String) async throws -> String {
        let process = try take()
        // The draft is written off this task, inside the deadline: a long draft can fill the pipe
        // before Claude starts reading.
        process.finishInput(text)
        let line: Data
        do {
            line = try await withDeadline(.seconds(40), orThrow: CorrectionError.failure(.slow, "Claude took too long to correct this text. Try again.")) {
                try await process.firstEvent(ofType: "result")
            }
        } catch {
            process.terminate()
            throw error is CancellationError || error is CorrectionError ? error : CorrectionError.message("Claude Code stopped unexpectedly. Try again.")
        }
        // The answer is in; the process gets a few seconds to shut down on its own, then is ended.
        process.retire(after: .seconds(5))
        return try ClaudeCode.decodeResult(ClaudeProcess.object(line))
    }

    private func take() throws -> ClaudeProcess {
        if let spare, spare.isRunning { self.spare = nil; return spare }
        spare = nil
        return try ClaudeProcess(runtime, arguments: ClaudeCode.correctionArguments(model: model, effort: effort))
    }

    private func drop(_ process: ClaudeProcess) {
        guard spare === process else { return }
        spare = nil; process.terminate()
    }
}

public extension ClaudeCode {
    /// Ends every CLI Oops started, when Oops quits.
    static func endRunningProcesses() { ClaudeProcess.endAll() }
}

// MARK: - Process

/// A running CLI with stdin open and stdout read as JSON lines. Output is bounded; stderr is discarded
/// (it can echo the draft).
final class ClaudeProcess: @unchecked Sendable {
    private let process = Process()
    private let stdin = Pipe(), stdout = Pipe()
    /// Every CLI still running, so quitting can end them all.
    private static let running = Mutex<Set<pid_t>>([])

    init(_ runtime: ClaudeCodeRuntime, arguments: [String]) throws {
        process.executableURL = runtime.executable
        process.arguments = arguments
        process.currentDirectoryURL = runtime.directory
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        // Caps each API request, so a process orphaned by a crash still ends within a minute.
        process.environment = ProcessInfo.processInfo.environment.merging(["API_TIMEOUT_MS": "45000"]) { _, cap in cap }
        process.terminationHandler = { ended in _ = Self.running.withLock { $0.remove(ended.processIdentifier) } }
        do { try process.run() } catch { throw CorrectionError.failure(.setup, "Claude Code couldn’t start. Check that it’s installed.") }
        let pid = process.processIdentifier
        if process.isRunning { Self.running.withLock { _ = $0.insert(pid) } }
    }

    /// SIGTERM, then SIGKILL two seconds later if it is still there.
    static func end(_ process: Process) {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        process.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { if process.isRunning { kill(pid, SIGKILL) } }
    }

    /// Quitting: SIGTERM to all, a short grace, then SIGKILL to whatever is left.
    static func endAll() {
        let pids = running.withLock { $0 }
        guard !pids.isEmpty else { return }
        for pid in pids { kill(pid, SIGTERM) }
        usleep(200_000)
        for pid in running.withLock({ $0 }) { kill(pid, SIGKILL) }
    }

    var isRunning: Bool { process.isRunning }

    /// Writes `text` and closes stdin on a background queue, so a full pipe never blocks the caller;
    /// ending the process breaks a write that is still waiting.
    func finishInput(_ text: String = "") {
        let handle = stdin.fileHandleForWriting
        DispatchQueue.global(qos: .userInitiated).async {
            if !text.isEmpty { try? handle.write(contentsOf: Data(text.utf8)) }
            try? handle.close()
        }
    }

    func terminate() { Self.end(process) }

    /// Ends the process after `grace` unless it has exited by then.
    func retire(after grace: Duration) {
        Task.detached { [self] in
            try? await Task.sleep(for: grace)
            terminate()
        }
    }

    /// The first stdout event of `type`, as its JSON line (parse it with `object`). Ends with an
    /// error if the process exits first.
    func firstEvent(ofType type: String) async throws -> Data {
        let reader = stdout.fileHandleForReading
        return try await withTaskCancellationHandler {
            var total = 0
            for try await line in reader.bytes.lines {
                total += line.utf8.count
                guard total <= 8_000_000 else { break }
                let data = Data(line.utf8)
                if Self.object(data)["type"] as? String == type { return data }
            }
            try Task.checkCancellation()
            throw CorrectionError.message("Claude Code stopped before answering. Try again.")
        } onCancel: { self.terminate() }
    }

    static func object(_ line: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] ?? [:]
    }

    /// All of stdout once the process exits, bounded. Cancelling ends the process, which ends the read.
    func readAll(limit: Int) async -> Data {
        await withTaskCancellationHandler {
            var data = Data()
            do { for try await byte in stdout.fileHandleForReading.bytes { data.append(byte); if data.count > limit { break } } } catch {}
            return data
        } onCancel: { self.terminate() }
    }
}
