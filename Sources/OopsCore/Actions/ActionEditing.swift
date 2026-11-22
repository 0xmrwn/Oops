import Foundation

public extension Action {
    /// A new action's starting point: no name, no instruction, the sparkles icon.
    static func blank(at place: ActionPlace) -> Action { Action(symbol: "sparkles", name: "", instruction: "", place: place) }

    /// Nothing written yet; a new action left so is not kept.
    var isUntouched: Bool { name.trimmed.isEmpty && instruction.trimmed.isEmpty }

    /// What the wheel and the editor call it.
    var title: String { name.trimmed.isEmpty ? "New action" : name }
}

public extension ActionLibrary {
    /// Whether a new action can go at `place`: the place is free and the wheel isn't full.
    func canAdd(at place: ActionPlace) -> Bool { actions.count < Self.limit && action(at: place) == nil }

    /// Applies an edit to a saved action, or to `draft`, the new action not kept yet: the draft joins the library once
    /// it has a name or an instruction. Returns the draft still waiting, nil once it's kept.
    mutating func apply(_ edit: Action, draft: Action?) -> Action? {
        guard let draft, edit.id == draft.id else {
            update(edit)
            return draft
        }
        guard !edit.isUntouched, (try? add(edit)) != nil else { return edit.normalized() }
        return nil
    }
}

public extension ActionChoice {
    static let empty = ActionChoice(name: "", values: [:])

    /// The next place to fill, in ring order (the arrows, then the diagonals), other than `skipping`.
    func nextEmpty(skipping: ActionPlace? = nil) -> ActionPlace? {
        ActionPlace.allCases.first { $0 != skipping && (values[$0] ?? "").isEmpty }
    }

    /// The choice with `value` at `place`; an empty value frees the place.
    func setting(_ value: String, at place: ActionPlace) -> ActionChoice {
        var choice = self
        choice.values[place] = value.isEmpty ? nil : value
        return choice
    }
}

/// How the instruction's text and its choice's mark are edited.
public enum ActionInstruction {
    /// Where Insert a choice puts the mark (UTF-16 offset) and what it inserts. At `caret` while the person is editing;
    /// otherwise after the last word, inside a closing full stop ("... its meaning [Choice]."). A space goes either
    /// side where a word would touch it, none before punctuation.
    public static func insertion(in text: String, caret: Int?) -> (location: Int, text: String) {
        let string = text as NSString
        var at = caret.map { min(max($0, 0), string.length) } ?? string.length
        if caret == nil {
            while at > 0, string.character(at: at - 1) == 10 { at -= 1 }
            if at > 0, string.character(at: at - 1) == 46 { at -= 1 }
        }
        func character(_ index: Int) -> Character? {
            UnicodeScalar(string.character(at: index)).map(Character.init) ?? " "
        }
        let before = at > 0 ? character(at - 1) : nil
        let after = at < string.length ? character(at) : nil
        var inserted = Action.choiceMark
        if let before, !before.isWhitespace { inserted = " " + inserted }
        if let after, !after.isWhitespace, !after.isPunctuation { inserted += " " }
        return (at, inserted)
    }

    /// What a paste brings: its words, never a mark (a choice comes only from Insert a choice).
    public static func pasted(_ text: String) -> String { text.replacingOccurrences(of: Action.choiceMark, with: "") }

    /// The instruction without its mark, the words closed up round the gap. Only the characters beside the mark are
    /// touched: spacing and punctuation elsewhere in the instruction are the person's own.
    public static func removingChoice(from instruction: String) -> String {
        guard let mark = instruction.range(of: Action.choiceMark) else { return instruction }
        var before = String(instruction[..<mark.lowerBound]), after = String(instruction[mark.upperBound...])
        let closing: Set<Character> = [".", ",", ";", ":", "!", "?"]
        if before.last == " ", let next = after.first, next == " " || closing.contains(next) { before.removeLast() }
        if before.isEmpty { after = String(after.drop { $0 == " " }) }
        if after.isEmpty { while before.last == " " { before.removeLast() } }
        return before + after
    }
}

/// Keeps the choice a deleted mark took with it, so undoing the deletion brings it back; Insert a choice forgets it, so
/// a mark the person asks for starts empty.
public struct ActionChoiceMemory: Sendable {
    private var removed: ActionChoice?

    public init() {}

    /// Sets `action`'s instruction and makes its choice agree with the mark in it.
    public mutating func apply(instruction: String, to action: inout Action) {
        action.instruction = instruction
        if instruction.contains(Action.choiceMark) {
            action.choice = action.choice ?? removed ?? .empty
            removed = nil
        } else if let choice = action.choice {
            removed = choice
            action.choice = nil
        }
    }

    /// The person is adding a choice, not undoing the removal of one.
    public mutating func forget() { removed = nil }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
