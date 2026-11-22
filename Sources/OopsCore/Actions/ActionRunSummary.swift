import Foundation

/// What the editor's Runs with row says will run, from names the caller has resolved.
public enum ActionRunSummary {
    /// "Haiku 5.5 · Low"; a model with no levels is its name alone. Same as Fix names Fix's model, at the lightest
    /// level it runs at: "Same as Fix · Haiku 5.5 · Low"; with no model at all, "Same as Fix".
    public static func model(sameAsFix: Bool, name: String?, effort: String?) -> String {
        ((sameAsFix ? ["Same as Fix"] : []) + [name, effort.map(ModelSelection.effortName)].compactMap(\.self)).joined(separator: " · ")
    }

    /// "Claude Code · Sonnet 5.5 · High · Web, commands": the harness, its model and level, then what it may do.
    public static func agent(model: String?, effort: String?, _ run: ActionAgentRun) -> String {
        let tools = [run.searchWeb ? "web" : nil, run.runCommands ? "commands" : nil, run.usesSetup ? "my setup" : nil]
            .compactMap(\.self).joined(separator: ", ")
        let allowed = tools.isEmpty ? nil : tools.prefix(1).uppercased() + tools.dropFirst()
        return ["Claude Code", model, effort.map(ModelSelection.effortName), allowed].compactMap(\.self).joined(separator: " · ")
    }
}
