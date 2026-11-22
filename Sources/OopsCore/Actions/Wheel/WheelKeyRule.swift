import CoreGraphics

/// The Actions shortcut as the wheel sees it, to tell its own key from every other.
public struct WheelChord: Equatable, Sendable {
    public var keyCode: Int64, flags: CGEventFlags
    public init(keyCode: Int64, flags: CGEventFlags) {
        self.keyCode = keyCode
        self.flags = flags
    }
}

/// What a key does while the wheel is open. The wheel takes the keys a person would use on it, so none of them
/// reaches the draft, and lets shortcuts through.
public enum WheelKey: Equatable, Sendable {
    /// Taken: the wheel hears it.
    case arrow(WheelArrow), escape, enter, erase, text
    /// Taken; nothing happens (space, tab, function keys).
    case swallow
    /// ⌘ or ⌃ with another key: the wheel closes and the key goes on.
    case leave
    /// The Actions chord itself, which goes on so its own handler toggles the wheel.
    case pass

    private static let modifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
    /// Keys that type nothing: function, navigation and keypad-clear keys, which report no characters either.
    private static let functionKeys: Set<Int64> = [
        71, 122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90, 115, 119, 116, 121, 114,
    ]

    public static func classify(keyCode: Int64, flags: CGEventFlags, characters: String, chord: WheelChord?) -> WheelKey {
        // The shortcut itself comes first: it may be an arrow with modifiers, and pressing it again must close the wheel.
        if let chord, chord.keyCode == keyCode, flags.intersection(modifiers) == chord.flags.intersection(modifiers) { return .pass }
        // Every other arrow counts with any modifiers: a held chord's modifiers are still down when the first arrow lands.
        if let arrow = WheelArrow(keyCode: keyCode) { return .arrow(arrow) }
        if flags.contains(.maskCommand) || flags.contains(.maskControl) { return .leave }
        switch keyCode {
        case 53: return .escape
        case 36, 76: return .enter
        case 51, 117: return .erase
        case 49, 48: return .swallow
        default: break
        }
        let scalars = characters.unicodeScalars
        if !scalars.isEmpty {
            return scalars.allSatisfy { $0.value > 32 && $0.value != 127 && ($0.value < 0xF700 || $0.value > 0xF8FF) } ? .text : .swallow
        }
        // No characters on a key that types: a dead key, waiting for the letter it accents.
        return functionKeys.contains(keyCode) ? .swallow : .text
    }
}
