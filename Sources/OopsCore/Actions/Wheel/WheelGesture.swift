import Foundation

public enum WheelArrow: CaseIterable, Sendable {
    case up, right, down, left

    /// Virtual key codes 126, 124, 125 and 123.
    public init?(keyCode: Int64) {
        switch keyCode {
        case 126: self = .up
        case 124: self = .right
        case 125: self = .down
        case 123: self = .left
        default: return nil
        }
    }

    public var place: ActionPlace {
        switch self {
        case .up: .up
        case .right: .right
        case .down: .down
        case .left: .left
        }
    }
}

/// Arrow keys as a pointing gesture: what is held points at a place, and letting go of the first key commits it.
/// Two arrows rarely come up in the same instant, so the commit waits a moment for the second.
public struct WheelGesture: Equatable, Sendable {
    /// A second key-up this soon after the first is still part of the same gesture.
    public static let grace: TimeInterval = 0.05
    /// Held arrows, in press order.
    public private(set) var held: [WheelArrow] = []
    public private(set) var pointed: ActionPlace?
    /// When the first key-up's place commits; set by that key-up, cleared by a press.
    public private(set) var commitAt: TimeInterval?
    private var resolved: ActionPlace?

    public init() {}

    /// What `held` points at among `filled`: one arrow its place; two adjacent arrows their diagonal when something is
    /// there, else the later-pressed of the two that has something; opposite arrows cancel each other.
    public static func resolve(_ held: [WheelArrow], among filled: Set<ActionPlace>) -> ActionPlace? {
        let vertical: WheelArrow? = held.contains(.up) != held.contains(.down) ? (held.contains(.up) ? .up : .down) : nil
        let horizontal: WheelArrow? = held.contains(.right) != held.contains(.left) ? (held.contains(.right) ? .right : .left) : nil
        if let vertical, let horizontal {
            let diagonal: ActionPlace = switch (vertical == .up, horizontal == .right) {
            case (true, true): .upRight
            case (false, true): .downRight
            case (false, false): .downLeft
            case (true, false): .upLeft
            }
            if filled.contains(diagonal) { return diagonal }
            return held.last { ($0 == vertical || $0 == horizontal) && filled.contains($0.place) }?.place
        }
        guard let one = vertical ?? horizontal, filled.contains(one.place) else { return nil }
        return one.place
    }

    public mutating func press(_ arrow: WheelArrow, among filled: Set<ActionPlace>) {
        if !held.contains(arrow) { held.append(arrow) }
        commitAt = nil
        resolved = nil
        pointed = Self.resolve(held, among: filled)
    }

    /// The first key-up fixes what was pointed at; the pointing itself only changes when the commit lands.
    public mutating func release(_ arrow: WheelArrow, at now: TimeInterval) {
        guard held.contains(arrow) else { return }
        if commitAt == nil {
            resolved = pointed
            commitAt = now + Self.grace
        }
        held.removeAll { $0 == arrow }
    }

    /// Hover: points without arrows; ignored while arrows are held or a release is about to commit, whose place the
    /// pointer must not change.
    public mutating func point(_ place: ActionPlace?) {
        guard held.isEmpty, commitAt == nil else { return }
        pointed = place
    }

    /// Once the grace has run out: the place resolved at the first key-up (held arrows cleared), or nil with the
    /// pointed place recomputed from what is still held. Nil before `commitAt`.
    public mutating func commit(at now: TimeInterval, among filled: Set<ActionPlace>) -> ActionPlace?? {
        // Times come from sums of doubles: an ulp short must not cost a whole frame.
        guard let due = commitAt, now >= due - 1e-9 else { return nil }
        commitAt = nil
        let pick = resolved
        resolved = nil
        if let pick {
            held = []
            return .some(pick)
        }
        pointed = Self.resolve(held, among: filled)
        return .some(nil)
    }

    public mutating func reset() { self = WheelGesture() }
}
