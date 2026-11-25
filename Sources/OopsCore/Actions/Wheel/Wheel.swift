import Foundation

/// Waits the wheel keeps, in seconds.
public enum WheelTiming {
    /// An arrow this soon after opening is a flick: the petals hold back and a quick release runs without them.
    public static let flick: TimeInterval = 0.17
    /// How long nothing is pointed at before every petal says its name.
    public static let linger: TimeInterval = 0.7
    /// From a ring's choice to its values leaving the centre, long enough for the chosen petal to flow in first.
    public static let choicesDelay: TimeInterval = 0.07
}

/// What the window and the run should do next. The wheel only decides; whoever owns the window carries these out.
public enum WheelEffect: Equatable, Sendable {
    /// The first ring, in place order with cardinals first.
    case bloom([ActionPlace])
    /// An early arrow: petals not out stay in, budding ones go back quickly.
    case skipBloom
    case point(ActionPlace?)
    case showNames
    /// The chosen petal flows into the centre, which shows its symbol.
    case select(ActionPlace, symbol: String)
    /// The centre becomes a field for an instruction, or a value at a ring, with `placeholder` in it.
    case beginTyping(placeholder: String)
    /// The words under the centre that say an action's ring takes a typed value, after the same linger as the names. The
    /// first ring says it with its cue as it opens (`WheelCue`).
    case showHint
    case bloomChoices([ActionPlace])
    case run(ActionInvocation)
    case restore
    case close
}

/// The wheel's state machine: which ring is open, what is pointed at and when it commits. Time is injected as seconds
/// on one clock, so every wait is testable without waiting.
public struct Wheel: Equatable, Sendable {
    public enum Level: Equatable, Sendable { case closed, root, choices(Action), typing(from: Typing) }
    /// Where the typing started: an instruction at the first ring, or a value at an action's ring.
    public enum Typing: Equatable, Sendable { case root, choices(Action) }

    public internal(set) var level = Level.closed
    public private(set) var library = ActionLibrary()
    public private(set) var restorable: UUID?
    public internal(set) var gesture = WheelGesture()
    public internal(set) var bloomed = false, named = false
    /// The centre takes typing here: the app in front keeps its field through it.
    public private(set) var canType = false
    /// The hint has shown at this ring.
    public internal(set) var hinted = false
    var enteredAt = 0.0, lingerAt = 0.0, choicesAt = 0.0
    var flicking = false
    private var placedOnScreen = false

    public init() {}

    public var isOpen: Bool { level != .closed }

    /// Places with something at the current level: saved actions' places, or the ring's non-blank values.
    public var filled: Set<ActionPlace> {
        switch level {
        case .closed: []
        case .root: Set(library.actions.map(\.place))
        case .typing: []
        case let .choices(action):
            Set((action.choice?.values ?? [:]).filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map(\.key))
        }
    }

    /// Opens the first ring. The window work is the caller's, so nothing is asked of it yet. `typing` says whether the
    /// centre may take typing in the app in front.
    public mutating func open(_ library: ActionLibrary, restorable: UUID?, typing: Bool = false, at now: TimeInterval) -> [WheelEffect] {
        self = Wheel()
        self.library = library
        self.restorable = restorable
        canType = typing
        level = .root
        enteredAt = now
        lingerAt = now + WheelTiming.linger
        return []
    }

    /// The window is on screen: the first ring may bloom, unless an early arrow is holding it back.
    public mutating func placed(at now: TimeInterval) -> [WheelEffect] {
        guard level == .root, !placedOnScreen else { return [] }
        placedOnScreen = true
        guard !flicking else { return [] }
        bloomed = true
        return [.bloom(WheelLayout.ordered(filled))] + (gesture.pointed.map { [.point($0)] } ?? [])
    }

    public mutating func press(_ arrow: WheelArrow, at now: TimeInterval) -> [WheelEffect] {
        // A release whose grace has run out is honoured before this press; only a press inside the grace cancels it.
        var effects = expired(at: now).effects
        guard isOpen, !isTyping else { return effects }
        // The second ring already out has nothing to hold back: only one that has not bloomed yet is flicked.
        if !flicking, now - enteredAt < WheelTiming.flick, level == .root || !bloomed {
            flicking = true
            effects.append(.skipBloom)
        }
        let before = gesture.pointed
        gesture.press(arrow, among: filled)
        return effects + repointed(from: before, at: now)
    }

    public mutating func release(_ arrow: WheelArrow, at now: TimeInterval) -> [WheelEffect] {
        let effects = expired(at: now).effects
        guard isOpen else { return effects }
        gesture.release(arrow, at: now)
        return effects
    }

    public mutating func hover(_ place: ActionPlace?, at now: TimeInterval) -> [WheelEffect] {
        var effects = expired(at: now).effects
        guard isOpen, !isTyping else { return effects }
        let before = gesture.pointed
        gesture.point(place.flatMap { filled.contains($0) ? $0 : nil })
        effects += repointed(from: before, at: now)
        return effects
    }

    public mutating func click(_ place: ActionPlace, at now: TimeInterval) -> [WheelEffect] {
        let effects = expired(at: now).effects
        guard isOpen, filled.contains(place) else { return effects }
        return effects + choose(place, at: now)
    }

    /// Grace, flick end, linger and the second ring's bloom, as time passes.
    public mutating func advance(to now: TimeInterval) -> [WheelEffect] {
        guard isOpen else { return [] }
        let committed = expired(at: now)
        if committed.chose { return committed.effects }
        var effects = committed.effects
        if flicking, Self.due(now, enteredAt + WheelTiming.flick), gesture.commitAt == nil {
            flicking = false
            // Before the window is up there is nothing to bloom: `placed` does it.
            if level != .root || placedOnScreen {
                bloomed = true
                lingerAt = now + WheelTiming.linger
                effects.append(level == .root ? .bloom(WheelLayout.ordered(filled)) : .bloomChoices(WheelLayout.ordered(filled)))
                if let pointed = gesture.pointed { effects.append(.point(pointed)) }
            }
        }
        if case .choices = level, !bloomed, !flicking, Self.due(now, choicesAt) {
            bloomed = true
            lingerAt = now + WheelTiming.linger
            effects.append(.bloomChoices(WheelLayout.ordered(filled)))
        }
        if lingering, Self.due(now, lingerAt) {
            if level == .root {
                named = true
                effects.append(.showNames)
            } else if canType, !hinted {
                hinted = true
                effects.append(.showHint)
            }
        }
        return effects
    }

    /// Nothing is pointed at a ring that is out: the names (first ring) and the hint (an action's ring) are waited for.
    private var lingering: Bool {
        guard bloomed, !flicking, gesture.pointed == nil, gesture.held.isEmpty, gesture.commitAt == nil else { return false }
        switch level {
        case .root: return !named
        case .choices: return canType && !hinted
        case .closed, .typing: return false
        }
    }

    /// The centre is a field.
    public var isTyping: Bool { if case .typing = level { true } else { false } }

    /// When `advance` next has something to do, or nil while nothing waits on time: until then the window can stop
    /// drawing frames once its motion is at rest.
    public var nextDue: TimeInterval? {
        guard isOpen else { return nil }
        var due: [TimeInterval] = []
        if let commitAt = gesture.commitAt { due.append(commitAt) }
        if flicking { due.append(enteredAt + WheelTiming.flick) }
        if case .choices = level, !bloomed, !flicking { due.append(choicesAt) }
        if lingering { due.append(lingerAt) }
        return due.min()
    }

    /// The release whose grace has run out, if any: what it chose (and then nothing else is due), or the pointing it
    /// leaves behind when letting go ended in neutral.
    private mutating func expired(at now: TimeInterval) -> (effects: [WheelEffect], chose: Bool) {
        guard isOpen else { return ([], false) }
        let before = gesture.pointed
        guard let result = gesture.commit(at: now, among: filled) else { return ([], false) }
        guard let place = result else { return (repointed(from: before, at: now), false) }
        let chosen = choose(place, at: now)
        return (chosen, !chosen.isEmpty)
    }

    /// Escape, a click outside, the shortcut again, or another feature taking over.
    public mutating func close() -> [WheelEffect] {
        guard isOpen else { return [] }
        level = .closed
        gesture.reset()
        return [.close]
    }

    /// Choosing a place at the current level, as a commit or a click.
    private mutating func choose(_ place: ActionPlace, at now: TimeInterval) -> [WheelEffect] {
        gesture.reset()
        switch level {
        case .closed, .typing:
            return []
        case .root:
            switch WheelDecision.root(place, in: library, restorable: restorable) {
            case .restore:
                level = .closed
                return [.select(place, symbol: "arrow.uturn.backward"), .restore, .close]
            case let .run(invocation):
                level = .closed
                return [.select(place, symbol: Self.symbol(of: invocation)), .run(invocation), .close]
            case let .openChoices(action):
                level = .choices(action)
                enteredAt = now
                bloomed = false
                named = false
                hinted = false
                flicking = false
                choicesAt = now + WheelTiming.choicesDelay
                return [.select(place, symbol: action.symbol)]
            case .nothing:
                return []
            }
        case let .choices(action):
            guard case let .run(invocation) = WheelDecision.value(place, of: action) else { return [] }
            level = .closed
            return [.select(place, symbol: action.symbol), .run(invocation), .close]
        }
    }

    /// A point effect when the pointing changed. Names wait for the pointing to stop, so letting go of a petal
    /// starts the wait again.
    private mutating func repointed(from before: ActionPlace?, at now: TimeInterval) -> [WheelEffect] {
        let after = gesture.pointed
        guard after != before else { return [] }
        if before != nil, after == nil, lingering { lingerAt = now + WheelTiming.linger }
        return [.point(after)]
    }

    private static func symbol(of invocation: ActionInvocation) -> String {
        switch invocation {
        case let .saved(action, _): action.symbol
        case .typed: "text.cursor"
        }
    }

    /// Times come from sums of doubles: an ulp short must not cost a whole frame.
    private static func due(_ now: TimeInterval, _ at: TimeInterval) -> Bool { now >= at - 1e-9 }
}
