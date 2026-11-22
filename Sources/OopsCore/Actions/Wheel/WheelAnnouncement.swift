import Foundation

/// What VoiceOver reads when the wheel opens and when a ring opens.
public enum WheelAnnouncement {
    public static func opening(_ petals: [WheelPetal]) -> String {
        guard !petals.isEmpty else { return "Actions. None saved yet." }
        return "Actions. " + list(petals)
    }

    public static func choices(_ name: String, _ pills: [WheelPetal]) -> String {
        guard !pills.isEmpty else { return "\(name). No values yet." }
        return "\(name). " + list(pills)
    }

    /// The direction as a person says it.
    public static func word(_ place: ActionPlace) -> String {
        switch place {
        case .up: "Up"
        case .upRight: "Up right"
        case .right: "Right"
        case .downRight: "Down right"
        case .down: "Down"
        case .downLeft: "Down left"
        case .left: "Left"
        case .upLeft: "Up left"
        }
    }

    private static func list(_ items: [WheelPetal]) -> String {
        items.map { "\(word($0.place)): \($0.title)." }.joined(separator: " ")
    }
}
