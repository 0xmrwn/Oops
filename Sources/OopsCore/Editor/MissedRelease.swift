import Foundation

/// One hold's release that may never come. Another app's event tap can swallow the key-up, and the hotkey's
/// release with it: the chord would then read as held for good, every later press of it would be dropped as a
/// repeat, and a dictation it started would never end. While the chord is held its key is sampled every
/// `interval`, and the release is inferred at the first sample that read up, so a hold is still measured to
/// when the key really came up. A watch lasts one hold: `HotkeyHolds` starts a new one at every edge.
public struct MissedRelease<Instant> {
    public static var interval: Duration { .milliseconds(50) }
    /// Two samples: a real release, delivered a moment after the key comes up, wins over the inferred one.
    public static var confirmations: Int { 2 }
    /// The session can keep a key down after the keyboard let it go (a remapper's virtual keyboard leaves it
    /// set): the hardware reading up this many samples in a row settles it, `ModifierRelease`'s 150 ms.
    public static var staleAfter: Int { 3 }
    /// Past this the watch stops without deciding anything: a key both states still read down is held, and a
    /// real hold is never cut. Thirty minutes is far beyond any dictation held on a key, so only a state that
    /// can't end gets here, and it is logged rather than sampled forever.
    public static var limit: Duration { .seconds(30 * 60) }

    private var sessionUp: (since: Instant, count: Int)?
    private var hardwareUp: (since: Instant, count: Int)?
    private var samples = 0

    public init() {}

    /// The first sample of an up the watch is still confirming.
    public var observedUp: Instant? { sessionUp?.since ?? hardwareUp?.since }
    public var isExpired: Bool { samples >= Int(Self.limit / Self.interval) }

    /// One sample of the chord's key in the session's state and the keyboard's. Returns when it came up once
    /// that is settled, else nil.
    public mutating func sample(session: Bool, hardware: Bool, at instant: Instant) -> Instant? {
        guard !isExpired else { return nil }
        samples += 1
        sessionUp = session ? nil : (sessionUp?.since ?? instant, (sessionUp?.count ?? 0) + 1)
        hardwareUp = hardware ? nil : (hardwareUp?.since ?? instant, (hardwareUp?.count ?? 0) + 1)
        if let up = sessionUp, up.count >= Self.confirmations { return up.since }
        if let up = hardwareUp, up.count >= Self.staleAfter { return up.since }
        return nil
    }
}

extension MissedRelease: Sendable where Instant: Sendable {}

/// The hotkeys' presses and releases, with a `MissedRelease` watch per held chord. Every edge the router
/// accepts starts the chord's watch over, so a release is only ever dated from the current hold.
public struct HotkeyHolds<Action: Hashable & Sendable, Instant> {
    public typealias Event = HotkeyRouter<Action>.Event
    public private(set) var router: HotkeyRouter<Action>
    private var watches: [Action: MissedRelease<Instant>] = [:]

    public init(_ actions: [Action]) { router = HotkeyRouter(actions) }

    /// The events a hotkey edge delivers, each with its instant. A press that finds its chord still held after
    /// an up was seen is a new press whose release went missing: that release is told first, at the up.
    public mutating func route(identity: UInt32, pressed: Bool, at instant: Instant) -> [(event: Event, at: Instant)] {
        var told: [(event: Event, at: Instant)] = []
        if pressed, let action = router.action(for: identity), router.held.contains(action), let up = watches[action]?.observedUp,
           let release = router.route(identity: identity, pressed: false) {
            watches[action] = nil
            told.append((release, up))
        }
        if let event = router.route(identity: identity, pressed: pressed) {
            watches[event.action] = nil
            told.append((event, instant))
        }
        return told
    }

    /// One round of samples over the held chords whose watch still runs. `keyDown` reads an action's key, nil
    /// when it has none. Returns the releases inferred, and the watches that reached their limit this round.
    public mutating func sample(at instant: Instant, keyDown: (Action) -> (session: Bool, hardware: Bool)?)
        -> (released: [(event: Event, at: Instant)], expired: [Action]) {
        var released: [(event: Event, at: Instant)] = [], expired: [Action] = []
        for action in router.held {
            var watch = watches[action] ?? MissedRelease()
            guard !watch.isExpired, let key = keyDown(action), let identity = router.identity(of: action) else { continue }
            let up = watch.sample(session: key.session, hardware: key.hardware, at: instant)
            watches[action] = watch
            if let up, let event = router.route(identity: identity, pressed: false) {
                watches[action] = nil
                released.append((event, up))
            } else if watch.isExpired { expired.append(action) }
        }
        return (released, expired)
    }

    /// Whether any held chord is still watched: the sampling stops once none is.
    public var isWatching: Bool { router.held.contains { watches[$0]?.isExpired != true } }

    /// Forgets every hold, as `HotkeyRouter.reset`.
    @discardableResult public mutating func reset() -> [Event] {
        watches = [:]
        return router.reset()
    }
}

extension HotkeyHolds: Sendable where Instant: Sendable {}
