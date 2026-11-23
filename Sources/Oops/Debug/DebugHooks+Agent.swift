#if DEBUG
import AppKit
import OopsCore

/// Lab triggers for agent runs, with the stub agent (`-StubAgent`): a starter action run as an agent on the lab's
/// draft, then acting on, dismissing or cancelling it from wherever the person is, as the drop and the
/// menu would. Every change of the run is a line in agent.jsonl; how each run ended is one in actions.jsonl.
@MainActor extension AppDelegate {
    func observeAgentTriggers(_ on: (String, @escaping @MainActor ([String: String]) -> Void) -> Void) {
        let agent = actions.agent
        agent.onEvent = { Self.record($0, to: "agent.jsonl") }
        let say = agent.refused
        agent.refused = { say($0); Self.record(["refused": $0], to: "agent.jsonl") }
        // The starter `name`, run as an agent, with `value` for its choice. As action-lab, never a person's own actions.
        // `options` (`model=haiku;effort=low;web=off;commands=on;instruction=…`) set how it runs, for a live run.
        on("agent-lab") { [weak self] info in
            guard let self, Self.labIsInFront() else { return }
            guard var action = ActionLibrary.starters.actions.first(where: { $0.name == info["name"] }) else {
                Self.record(["outcome": "unknown"], to: "actions.jsonl"); return
            }
            action.runsWith.kind = .agent
            for option in (info["options"] ?? "").split(separator: ";") {
                let pair = option.split(separator: "=", maxSplits: 1).map(String.init)
                guard pair.count == 2 else { continue }
                switch pair[0] {
                case "model": action.runsWith.agent.model = pair[1]
                case "effort": action.runsWith.agent.effort = pair[1]
                case "web": action.runsWith.agent.searchWeb = pair[1] == "on"
                case "commands": action.runsWith.agent.runCommands = pair[1] == "on"
                case "instruction": action.instruction = pair[1]
                default: break
                }
            }
            if self.drop.holder == .fix, !self.session.isBusy { self.session.capsule.hide() }
            self.recordAction(self.actions.run(.saved(action, value: info["value"].flatMap { $0.isEmpty ? nil : $0 })))
        }
        // The starter `name` as an agent, run by Settings' Try on its own draft, as its Run button would.
        on("agent-try") { info in
            guard var action = ActionLibrary.starters.actions.first(where: { $0.name == info["name"] }) else { return }
            action.runsWith.kind = .agent
            Task { await ActionTryModel.shared.run(.saved(action, value: nil)) }
        }
        // These act wherever the person is, as the menu's items do.
        on("agent-act") { _ in agent.act() }
        on("agent-dismiss") { _ in agent.dismiss() }
        on("agent-cancel") { _ in agent.cancel() }
        on("agent-state") { [weak self] _ in
            guard let self else { return }
            var entry = ["phase": String(describing: agent.flow.phase), "mark": String(describing: agent.flow.mark),
                         "escape": self.escapes.armed[.agent] == nil ? "no" : "yes", "confirm": agent.confirming ? "yes" : "no", "copy": agent.copyable == nil ? "no" : "yes", "restorable": self.actions.canRestore ? "yes" : "no", "front": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""]
            entry.merge(agent.drop.state) { a, _ in a }
            Self.record(entry, to: "agent.jsonl")
        }
    }
}
#endif
