import Foundation
import OopsCore

/// The wheels the tests open: the starters (up, right, down and left) and a fuller one with two diagonals.
enum WheelFixtures {
    static let starters = ActionLibrary.starters

    static let eight: ActionLibrary = {
        var library = starters
        library.actions.append(Action(symbol: "text.alignleft", name: "Summarize", instruction: "Summarize the text.", place: .upRight))
        library.actions.append(Action(symbol: "list.bullet", name: "Bullet points", instruction: "Make the text bullet points.", place: .downLeft))
        return library
    }()

    static func action(_ name: String, in library: ActionLibrary = starters) -> Action {
        library.actions.first { $0.name == name } ?? library.actions[0]
    }

    static var places: Set<ActionPlace> { Set(starters.actions.map(\.place)) }

    /// A petal per place, as the first ring shows them.
    static func petals(_ places: [ActionPlace], symbol: String? = "star") -> [WheelPetal] {
        places.map { WheelPetal(place: $0, title: "Name", symbol: symbol, width: 60) }
    }

    /// A wheel opened at 0 and on screen at 0.03.
    static func opened(_ library: ActionLibrary = starters, restorable: UUID? = nil) -> Wheel {
        var wheel = Wheel()
        _ = wheel.open(library, restorable: restorable, at: 0)
        _ = wheel.placed(at: 0.03)
        return wheel
    }

    /// Press and let go of one arrow, then the effects once its grace has run out.
    static func tap(_ wheel: inout Wheel, _ arrow: WheelArrow, at time: TimeInterval) -> [WheelEffect] {
        _ = wheel.press(arrow, at: time)
        _ = wheel.release(arrow, at: time + 0.05)
        return wheel.advance(to: time + 0.10)
    }
}
