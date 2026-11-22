import Foundation

public enum ActionLibraryError: Error, Equatable, Sendable { case full, placeTaken, duplicate }

/// Everything Actions keeps: the saved actions and how an instruction typed on the fly runs.
public struct ActionLibrary: Codable, Equatable, Sendable {
    public static let limit = 8
    public var version: Int, actions: [Action], typed: ActionRunsWith

    public init(version: Int = 1, actions: [Action] = [], typed: ActionRunsWith = .sameAsFix) {
        self.version = version
        self.actions = actions
        self.typed = typed
    }

    /// What a new library holds. They are ordinary actions, edited and deleted like any other.
    public static let starters = ActionLibrary(actions: [
        Action(symbol: "sparkles", name: "Sharpen prompt",
               instruction: "Make this prompt " + Action.choiceMark + " so a model does the task better. Keep my intent and my constraints.",
               choice: ActionChoice(name: "How", values: [.up: "Clearer", .right: "More ambitious", .down: "Deeper"]), place: .up),
        Action(symbol: "globe", name: "Translate", instruction: "Translate the text into " + Action.choiceMark + ". Keep names, formatting and tone.",
               choice: ActionChoice(name: "Language", values: [.up: "French", .right: "Spanish", .down: "German", .left: "Italian"]), place: .right),
        Action(symbol: "arrow.down.right.and.arrow.up.left", name: "Shorten", instruction: "Make the text shorter without losing its meaning.", place: .down),
        Action(symbol: "text.bubble", name: "Tone", instruction: "Rewrite the text in a " + Action.choiceMark + " tone. Keep the meaning.",
               choice: ActionChoice(name: "Tone", values: [.up: "Formal", .right: "Friendly", .down: "Direct", .left: "Concise"]), place: .left),
    ])

    public func action(at place: ActionPlace) -> Action? { actions.first { $0.place == place } }

    public mutating func add(_ action: Action) throws {
        guard actions.count < Self.limit else { throw ActionLibraryError.full }
        guard !actions.contains(where: { $0.id == action.id }) else { throw ActionLibraryError.duplicate }
        guard self.action(at: action.place) == nil else { throw ActionLibraryError.placeTaken }
        actions.append(action.normalized())
    }

    public mutating func update(_ action: Action) {
        guard let index = actions.firstIndex(where: { $0.id == action.id }) else { return }
        move(action.id, to: action.place)
        actions[index] = action.normalized()
    }

    /// An action already at `place` takes the place the moved one leaves; nothing else moves.
    public mutating func move(_ id: UUID, to place: ActionPlace) {
        guard let index = actions.firstIndex(where: { $0.id == id }), actions[index].place != place else { return }
        if let other = actions.firstIndex(where: { $0.place == place }) { actions[other].place = actions[index].place }
        actions[index].place = place
    }

    public mutating func remove(_ id: UUID) { actions.removeAll { $0.id == id } }
}
