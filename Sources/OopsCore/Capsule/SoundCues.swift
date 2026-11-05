import Foundation

/// Oops's three cues, rendered by `design/sound/generate.py`. Start is one voice; success and failure ship three
/// takes each that differ only in the bubble's shape, played in cycle.
public enum SoundCue: String, CaseIterable, Sendable {
    case start, success, failure
    public var takes: Int { self == .start ? 1 : 3 }
    /// The bundled file's name, without its `.caf` extension.
    public func file(take: Int) -> String { self == .start ? "oops-start" : "oops-\(rawValue)-\(take + 1)" }
}

/// What the drop is doing, as far as its sound goes.
public enum DropState: Equatable, Sendable {
    /// Invoked or working: a correction is under way.
    case starting
    /// The eyes swing into the check (fixed, already clear).
    case fixed
    /// The eyes look away (failed, couldn't paste).
    case failed
    /// The user's own action answered: cancel, copy, revert. No echo.
    case quiet
}

public enum SoundCues {
    /// The cue a change of the drop plays, if any, and how long after the state change it starts.
    /// `previous` is nil when the drop is entering (it pops in); a cue plays once per change, so a
    /// working phase after invoked, or a relabelled failure, stays silent.
    public static func cue(from previous: DropState?, to state: DropState, reduceMotion: Bool) -> (cue: SoundCue, delay: Double)? {
        guard state != previous else { return nil }
        switch state {
        case .starting: return (.start, previous == nil ? Delay.appears(reduceMotion) : Delay.restarts)
        case .fixed: return (.success, Delay.succeeds(reduceMotion))
        case .failed: return (.failure, Delay.fails(reduceMotion))
        case .quiet: return nil
        }
    }

    /// Each cue lands on the drop's own motion (EyesDrop's springs, README "Sync with the drop"),
    /// measured from the frame where the state change is drawn.
    enum Delay {
        /// The start's peak (15 ms into the file) on the pop-in's fastest growth, at 90 ms.
        static func appears(_ reduceMotion: Bool) -> Double { reduceMotion ? 0.085 : 0.075 }
        /// The drop is already up: the start's peak as the eyes set off toward the text.
        static let restarts = 0.03
        /// The long E6 (99 ms into the file) rings out as the check arrives, at 230 ms.
        static func succeeds(_ reduceMotion: Bool) -> Double { reduceMotion ? 0.05 : 0.13 }
        /// D5 as the glance sets off; B4 sinks while the eyes travel and settles as they land.
        static func fails(_ reduceMotion: Bool) -> Double { reduceMotion ? 0 : 0.03 }
    }
}

/// Takes in turn, so the same take never plays twice in a row.
public struct TakeCycle: Sendable {
    private var last: [SoundCue: Int] = [:]
    public init() {}
    public mutating func next(_ cue: SoundCue) -> Int {
        let take = ((last[cue] ?? -1) + 1) % cue.takes
        last[cue] = take
        return take
    }
}
