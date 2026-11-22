import Foundation
import OopsCore

/// What an agent action runs with: Claude Code, found as Fix finds it, with the action's model as Claude Code lists it.
extension ProviderStore {
    /// A runner for one agent run. Throws, and so runs nothing, unless Claude Code is set up in Settings → Providers and
    /// nothing is wrong with it, as the Runs with row says: an executable found on the Mac isn't enough.
    func agentRunner() throws -> any AgentRunning {
        #if DEBUG
        if let control = DebugFlags.stubAgent { return try StubAgent.make(control: control) }
        #endif
        try checkAgentProvider()
        guard let runtime = claudeRuntime ?? ClaudeCodeRuntime.locate(directory: Self.claudeDirectory, askShell: false) else {
            throw ClaudeAgentError.notInstalled
        }
        claudeRuntime = runtime
        return ClaudeAgentRunner(executable: runtime.executable, limit: DebugFlags.agentLimit ?? ClaudeAgent.limit)
    }

    /// Claude Code as a provider: set up, installed, signed in and reachable (a check under way counts as fine).
    func checkAgentProvider() throws {
        switch agentProblem {
        case nil: return
        case "Signed out"?: throw CorrectionError.failure(.signIn, "Sign in to Claude Code from Settings → Providers to run agent actions.")
        case "Not installed"?, "Not set up"?: throw ClaudeAgentError.notInstalled
        case let problem?: throw CorrectionError.failure(.setup, "Claude Code can’t run agent actions right now (\(problem)). Check it in Settings → Providers.")
        }
    }

    /// The run as Claude Code can take it: a model it still lists, at an effort that model offers.
    func agentRun(_ run: ActionAgentRun) -> ActionAgentRun {
        guard let model = agentModel(run) else { return run }
        var resolved = run
        resolved.model = model.id
        resolved.effort = ModelSelection.nearestEffort(run.effort, in: model)
        return resolved
    }
}
