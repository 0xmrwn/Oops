import Foundation

/// Which shortcut action a hotkey event belongs to, and whether it is worth telling. Each action
/// registers under an identity of its own, so two chords held at once keep their presses and releases apart.
public struct HotkeyRouter<Action: Hashable & Sendable>: Sendable {
    public enum Phase: Equatable, Sendable { case pressed, released }
    public struct Event: Equatable, Sendable {
        public let action: Action
        public let phase: Phase
        public init(action: Action, phase: Phase) { self.action = action; self.phase = phase }
    }

    private let actions: [Action]
    /// The actions whose chords are down.
    public private(set) var held: Set<Action> = []

    public init(_ actions: [Action]) { self.actions = actions }

    /// The identity `action` registers under: its place in the list, from 1.
    public func identity(of action: Action) -> UInt32? { actions.firstIndex(of: action).map { UInt32($0 + 1) } }

    public func action(for identity: UInt32) -> Action? {
        identity >= 1 && identity <= UInt32(actions.count) ? actions[Int(identity) - 1] : nil
    }

    /// The event to deliver, if any. A held chord repeats its press: one press per hold. A release
    /// with no press before it (a chord already down when it was registered) is not told.
    public mutating func route(identity: UInt32, pressed: Bool) -> Event? {
        guard let action = action(for: identity) else { return nil }
        if pressed { return held.insert(action).inserted ? Event(action: action, phase: .pressed) : nil }
        return held.remove(action) != nil ? Event(action: action, phase: .released) : nil
    }

    /// Forgets what is held: the registrations it was heard through are gone.
    public mutating func reset() { held = [] }
}
