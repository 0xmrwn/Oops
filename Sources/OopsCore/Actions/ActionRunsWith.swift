/// One plain model call with no tools. No choice means Fix's model.
public struct ActionModelRun: Codable, Equatable, Sendable {
    public var choice: ModelSelection.Choice?, effort: String?
    public init(choice: ModelSelection.Choice? = nil, effort: String? = nil) {
        self.choice = choice
        self.effort = effort
    }
}

/// A run through Claude Code, with only the tools its switches grant.
public struct ActionAgentRun: Codable, Equatable, Sendable {
    public var model: String?, effort: String?
    public var searchWeb: Bool, runCommands: Bool, usesSetup: Bool

    public init(model: String? = nil, effort: String? = nil, searchWeb: Bool = true, runCommands: Bool = false, usesSetup: Bool = false) {
        self.model = model
        self.effort = effort
        self.searchWeb = searchWeb
        self.runCommands = runCommands
        self.usesSetup = usesSetup
    }
}

/// How an action runs. Both sides are kept, so switching to the other and back loses nothing.
public struct ActionRunsWith: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case model, agent }
    public var kind: Kind, model: ActionModelRun, agent: ActionAgentRun

    public init(kind: Kind = .model, model: ActionModelRun = .init(), agent: ActionAgentRun = .init()) {
        self.kind = kind
        self.model = model
        self.agent = agent
    }

    public static let sameAsFix = ActionRunsWith()
}
