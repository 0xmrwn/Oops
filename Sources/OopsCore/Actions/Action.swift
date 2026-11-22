import Foundation

/// The eight places on the wheel, in the order a choice's values fill them: the arrows first, then the diagonals.
public enum ActionPlace: String, Codable, CodingKeyRepresentable, CaseIterable, Sendable {
    case up, right, down, left, upRight, downRight, downLeft, upLeft

    public var isDiagonal: Bool {
        switch self {
        case .up, .right, .down, .left: false
        case .upRight, .downRight, .downLeft, .upLeft: true
        }
    }
}

/// The one question an action may ask before it runs, such as Translate's language: a name and up to eight values,
/// each at its place on the second ring.
public struct ActionChoice: Codable, Equatable, Sendable {
    public var name: String
    public var values: [ActionPlace: String]

    public init(name: String, values: [ActionPlace: String]) {
        self.name = name
        self.values = values
    }

    /// The values offered, in ring order, without the blank ones.
    public var ordered: [String] {
        ActionPlace.allCases.compactMap { values[$0] }.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

/// A saved instruction that rewrites the focused draft. Its place on the wheel is its own and never reflows when
/// other actions come and go.
public struct Action: Identifiable, Codable, Equatable, Sendable {
    /// Where the choice's value goes in `instruction`: the character text storage writes for an attachment, so the
    /// editor's pill and the stored text agree.
    public static let choiceMark = "\u{FFFC}"

    public var id: UUID, symbol: String, name: String, instruction: String
    public var choice: ActionChoice?, place: ActionPlace, runsWith: ActionRunsWith

    public init(id: UUID = UUID(), symbol: String, name: String, instruction: String, choice: ActionChoice? = nil,
                place: ActionPlace, runsWith: ActionRunsWith = .sameAsFix) {
        self.id = id
        self.symbol = symbol
        self.name = name
        self.instruction = instruction
        self.choice = choice
        self.place = place
        self.runsWith = runsWith
    }

    /// The action with its mark and its choice agreeing: one mark at most, and neither without the other.
    public func normalized() -> Self {
        var action = self
        guard let mark = instruction.range(of: Self.choiceMark) else {
            action.choice = nil
            return action
        }
        let tail = instruction[mark.upperBound...].replacingOccurrences(of: Self.choiceMark, with: "")
        action.instruction = instruction[..<mark.lowerBound] + (choice == nil ? "" : Self.choiceMark) + tail
        return action
    }
}
