import Foundation

/// What runs an action and what it may do, from names the caller has resolved. The editor's Runs with row draws these
/// parts, and `text` and `spoken` say the same parts, so the row, the wheel's tooltip and VoiceOver never disagree.
public struct ActionRunSummary: Equatable, Sendable {
    /// What an agent may do, in the order the Runs with page lists its switches.
    public enum Permission: Hashable, Sendable {
        case web, commands, setup

        /// The row's short label.
        public var label: String {
            switch self {
            case .web: "Web"
            case .commands: "Commands"
            case .setup: "My setup"
            }
        }

        var phrase: String {
            switch self {
            case .web: "search the web"
            case .commands: "run commands"
            case .setup: "use your setup"
            }
        }
    }

    /// The provider whose mark goes before the model: Claude Code's for an agent.
    public let providerID: String?
    public let model: String?
    public let effort: String?
    public let sameAsFix: Bool
    public let agent: Bool
    public let permissions: [Permission]
    /// Why the agent can't run, as Providers says it: "Signed out".
    public let problem: String?

    /// A model with no levels has none; Same as Fix names Fix's model at the lightest level it runs at, and with no
    /// model at all is Same as Fix alone.
    public static func model(sameAsFix: Bool, providerID: String?, name: String?, effort: String?) -> Self {
        .init(providerID: providerID, model: name, effort: effort, sameAsFix: sameAsFix, agent: false, permissions: [], problem: nil)
    }

    public static func agent(model: String?, effort: String?, _ run: ActionAgentRun, problem: String?) -> Self {
        let permissions: [Permission] = [run.searchWeb ? .web : nil, run.runCommands ? .commands : nil, run.usesSetup ? .setup : nil]
            .compactMap(\.self)
        return .init(providerID: "claude-code", model: model, effort: effort, sameAsFix: false, agent: true, permissions: permissions,
                     problem: problem)
    }

    public var level: String? { effort.map(ModelSelection.effortName) }

    /// One line for a tooltip: "Same as Fix · Haiku 5.5 · Low", "Claude Code · Sonnet 5.5 · High · Web, commands".
    public var text: String {
        guard agent else { return ((sameAsFix ? ["Same as Fix"] : []) + [model, level].compactMap(\.self)).joined(separator: " · ") }
        let tools = permissions.map(\.label).joined(separator: ", ")
        let allowed = tools.isEmpty ? nil : String(tools.prefix(1)) + tools.dropFirst().lowercased()
        return ["Claude Code", problem, model, level, allowed].compactMap(\.self).joined(separator: " · ")
    }

    /// One sentence for VoiceOver, what stops the run first: "Claude Code is signed out; Sonnet 5.5, Extra High, with
    /// Claude Code; can search the web and use your setup".
    public var spoken: String {
        let named = [model, level].compactMap(\.self)
        guard agent else {
            guard sameAsFix else { return named.joined(separator: ", ") }
            return named.isEmpty ? "Same as Fix" : (named + ["same as Fix"]).joined(separator: ", ")
        }
        let phrases = permissions.map(\.phrase)
        let tools = phrases.count < 2 ? phrases.first : phrases.dropLast().joined(separator: ", ") + " and " + phrases[phrases.count - 1]
        let sentence = (named + ["with Claude Code"]).joined(separator: ", ") + "; " + (tools.map { "can " + $0 } ?? "no tools")
        guard let problem else { return sentence }
        let state = problem.prefix(1).lowercased() + problem.dropFirst()
        return "Claude Code \(state.hasPrefix("can") ? "" : "is ")\(state); \(sentence)"
    }
}
