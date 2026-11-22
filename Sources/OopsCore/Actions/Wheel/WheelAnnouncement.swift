import Foundation

/// What VoiceOver reads when the wheel opens and when a ring opens.
public enum WheelAnnouncement {
    /// `typing`: the centre takes typing here, which is said last.
    public static func opening(_ petals: [WheelPetal], typing: Bool = false) -> String {
        let said = petals.isEmpty ? "Actions. None saved yet." : "Actions. " + list(petals)
        return typing ? said + " Or type an instruction." : said
    }

    public static func choices(_ name: String, _ pills: [WheelPetal], typing: Bool = false) -> String {
        let said = pills.isEmpty ? "\(name). No values yet." : "\(name). " + list(pills)
        return typing ? said + " Or type one." : said
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
