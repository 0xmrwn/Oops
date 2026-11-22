import Foundation
import OSLog

public struct ClaudeAgentRequest: Equatable, Sendable {
    public var run: ActionAgentRun, instructions: String, input: String

    public init(run: ActionAgentRun, instructions: String, input: String) {
        self.run = run
        self.instructions = instructions
        self.input = input
    }
}

public enum ClaudeAgentUpdate: Equatable, Sendable {
    case step(ClaudeAgentStep), answer(String)
}

public protocol AgentRunning: Sendable {
    func run(_ request: ClaudeAgentRequest) -> AsyncThrowingStream<ClaudeAgentUpdate, Error>
}

public struct ClaudeAgentEnvironment: Sendable {
    public var home: URL, runs: URL
    public var sandboxAvailable: @Sendable () -> Bool
    public var grace: Duration, handshake: Duration

    var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    var hostEnvironment = ProcessInfo.processInfo.environment
    var observeResult: (@Sendable (URL, [ClaudeAgent.Refusal]) -> Void)?

    public static var live: Self {
        let files = FileManager.default
        let temp = URL(fileURLWithPath: ClaudeAgentFolder.realPath(files.temporaryDirectory))
        return Self(home: files.homeDirectoryForCurrentUser, runs: temp.appendingPathComponent("oops-agent-runs"),
                    sandboxAvailable: { FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec") },
                    grace: .seconds(2), handshake: .seconds(5))
    }

    var skills: URL? {
        let url = home.appendingPathComponent(".claude/skills")
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue ? url : nil
    }
}

public struct ClaudeAgentRunner: AgentRunning {
    private let executable: URL, environment: ClaudeAgentEnvironment, limit: Duration
    private typealias Updates = AsyncThrowingStream<ClaudeAgentUpdate, Error>.Continuation
    private static let log = Logger(subsystem: "dev.0xmrwn.oops", category: "agent")

    public init(executable: URL, environment: ClaudeAgentEnvironment = .live, limit: Duration = ClaudeAgent.limit) {
        self.executable = executable
        self.environment = environment
        self.limit = limit
    }

    public func run(_ request: ClaudeAgentRequest) -> AsyncThrowingStream<ClaudeAgentUpdate, Error> {
        AsyncThrowingStream { updates in
            let task = Task {
                do {
                    try await perform(request, updates: updates)
                    updates.finish()
                } catch { updates.finish(throwing: error) }
            }
            updates.onTermination = { _ in task.cancel() }
        }
    }

    private func perform(_ request: ClaudeAgentRequest, updates: Updates) async throws {
        guard environment.sandboxAvailable() else { throw ClaudeAgentError.sandboxUnavailable }
        let skills = request.run.usesSetup ? environment.skills : nil
        let folder = try ClaudeAgentFolder.make(in: environment.runs, skills: skills)
        defer { folder.remove() }
        var instruction = request.instructions
        if request.run.usesSetup, !ClaudeSkills.mentions(in: instruction).isEmpty,
           let names = await ClaudeCodeRuntime(executable: executable, directory: folder.url).stagedSkillNames(environment: environment) {
            instruction = ClaudeSkills.rewrite(instruction, known: names)
        }
        let memory = request.run.usesSetup ? try? String(contentsOf: environment.home.appendingPathComponent(".claude/CLAUDE.md"), encoding: .utf8) : nil
        let prompt = ClaudeAgent.instructions(instruction, memory: memory, usesSkills: request.run.usesSetup)
        let dirs = skills.map(ClaudeAgentFolder.skillDirectories) ?? []
        // Permission patterns cannot quote a comma, wildcard or closing parenthesis in a path.
        guard dirs.allSatisfy({ $0.rangeOfCharacter(from: CharacterSet(charactersIn: ",()*?[]{}\\").union(.controlCharacters)) == nil }) else {
            throw ClaudeAgentError.sandboxUnavailable
        }
        let settings = ClaudeAgent.settings(folder: folder.url.path, home: ClaudeAgentFolder.realPath(environment.home), skillDirectories: dirs)
        let flags = ClaudeAgent.arguments(request.run, instructions: prompt, settings: settings, skillDirectories: dirs)
        try Task.checkCancellation()
        let process = try ClaudeAgentProcess(executable: executable, arguments: flags, folder: folder.url, environment: environment.hostEnvironment)
        process.send(request.input)
        updates.yield(.step(.starting))
        do {
            try await withDeadline(limit, orThrow: ClaudeAgentError.timedOut, sleep: environment.sleep) {
                try await read(process, folder: folder.url, updates: updates)
            }
        } catch {
            await process.end(grace: environment.grace)
            throw error
        }
        await process.end(grace: environment.grace)
    }

    private func read(_ process: ClaudeAgentProcess, folder: URL, updates: Updates) async throws {
        var last = ClaudeAgentStep.starting
        for try await line in process.lines {
            try Task.checkCancellation()
            switch ClaudeAgentEvents.decode(line) {
            case .steps(let steps):
                for step in steps where step != last { updates.yield(.step(step)); last = step }
            case .result(let object):
                let (raw, refused) = try ClaudeAgent.decodeResult(object)
                environment.observeResult?(folder, refused)
                for refusal in refused { Self.log.info("Claude Code refused \(refusal.tool, privacy: .public)") }
                updates.yield(.step(.done))
                updates.yield(.answer(raw))
                return
            case .denied, .ignored: break
            }
        }
        try Task.checkCancellation()
        throw try await process.exitError()
    }
}
