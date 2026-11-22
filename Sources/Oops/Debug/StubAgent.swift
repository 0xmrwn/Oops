#if DEBUG
import Foundation
import OopsCore

/// End-to-end runs only (`-StubAgent <control.json>`, a launch argument, never saved): an agent that streams the
/// steps a control file lists and answers from it, so every state of an agent run can be driven without Claude Code
/// or any model. The file holds `steps` (`{"think":true}`, `{"search":"q"}`, `{"read":"https://example.com/x"}`,
/// `{"run":true}`, `{"skill":"name"}`), `stepMs` between them (400 by default), then `answer` (returned as the schema
/// object) or `raw` (verbatim), or `fail` (timeout, sandbox, signIn, limit, stopped, output); `delayMs` waits before the
/// answer, and `limitMs` ends the run as the real limit would (`-AgentLimitMs`, else five minutes). `unavailable`
/// (notInstalled, signedOut) refuses to start, as a missing or signed-out Claude Code does. Each run counts itself in
/// `<control>.calls`, and writes how it ended (finished, failed, timedOut or cancelled) to `<control>.ended`.
struct StubAgent: AgentRunning {
    let control: URL

    static func make(control: URL) throws -> StubAgent {
        switch script(control)["unavailable"] as? String {
        case "notInstalled": throw ClaudeAgentError.notInstalled
        case "signedOut": throw CorrectionError.failure(.signIn, "Stub: signed out.")
        default: return StubAgent(control: control)
        }
    }

    private static func script(_ control: URL) -> [String: Any] {
        (try? Data(contentsOf: control)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }

    func run(_ request: ClaudeAgentRequest) -> AsyncThrowingStream<ClaudeAgentUpdate, Error> {
        let calls = control.appendingPathExtension("calls"), ended = control.appendingPathExtension("ended")
        let count = (try? String(contentsOf: calls, encoding: .utf8)).flatMap { Int($0) } ?? 0
        try? String(count + 1).write(to: calls, atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(at: ended)
        let control = control, input = request.input
        return AsyncThrowingStream { updates in
            let task = Task {
                let limit = (Self.script(control)["limitMs"] as? Int).map { Duration.milliseconds($0) } ?? DebugFlags.agentLimit ?? ClaudeAgent.limit
                let end: String
                do {
                    try await withDeadline(limit, orThrow: ClaudeAgentError.timedOut) {
                        try await Self.perform(Self.script(control), input: input) { updates.yield($0) }
                    }
                    updates.finish(); end = "finished"
                } catch is CancellationError {
                    updates.finish(throwing: CancellationError()); end = "cancelled"
                } catch {
                    updates.finish(throwing: error); end = error as? ClaudeAgentError == .timedOut ? "timedOut" : "failed"
                }
                try? end.write(to: ended, atomically: true, encoding: .utf8)
            }
            updates.onTermination = { _ in task.cancel() }
        }
    }

    private static func perform(_ script: [String: Any], input: String, yield: @Sendable (ClaudeAgentUpdate) -> Void) async throws {
        let pause = Duration.milliseconds(script["stepMs"] as? Int ?? 400)
        yield(.step(.starting))
        for entry in script["steps"] as? [[String: Any]] ?? [] {
            try await Task.sleep(for: pause)
            if let step = step(entry) { yield(.step(step)) }
        }
        if let delay = script["delayMs"] as? Int { try await Task.sleep(for: .milliseconds(delay)) }
        try Task.checkCancellation()
        switch script["fail"] as? String {
        case "timeout": throw ClaudeAgentError.timedOut
        case "sandbox": throw ClaudeAgentError.sandboxUnavailable
        case "signIn": throw CorrectionError.failure(.signIn, "Stub failure: signIn.")
        case "limit": throw CorrectionError.failure(.limit, "Stub failure: limit.")
        case "stopped": throw ClaudeAgentError.stopped
        case "output": throw ActionOutputError.malformed
        default: break
        }
        yield(.step(.done))
        if let raw = script["raw"] as? String { return yield(.answer(raw)) }
        let answer = script["answer"] as? String ?? input
        yield(.answer(String(decoding: try JSONSerialization.data(withJSONObject: ["text": answer]), as: UTF8.self)))
    }

    private static func step(_ entry: [String: Any]) -> ClaudeAgentStep? {
        if entry["think"] != nil { return .thinking }
        if let query = entry["search"] as? String { return .searching(query) }
        if let url = entry["read"] as? String { return URL(string: url)?.host.map { .reading($0) } }
        if entry["run"] != nil { return .running }
        if let skill = entry["skill"] as? String { return .usingSkill(skill) }
        return nil
    }
}
#endif
