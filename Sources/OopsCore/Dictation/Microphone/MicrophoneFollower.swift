/// When an open microphone resolves its input again: after the default input, the list of inputs, the lid or a
/// setting changed, or while it stands in for a picked microphone that is missing. It switches only while capture
/// is idle, since replacing the stream would discard a recording, and keeps the open input when it resolves to it
/// again. Ported from the route and selection side of Hex's `RecoveringAudioInput` and `MicrophoneRecovery` in
/// `src/audio.rs` (v3.4.0); Hex's stream recovery is the source's loss here (`DictationAudioSource.watchLoss`).
/// Resolving and opening are the caller's: `poll` says when, `resolved` takes what it found.
public struct MicrophoneFollower: Sendable {
    public typealias Instant = ContinuousClock.Instant

    public static let retryInitial: Duration = .milliseconds(250)
    public static let retryMax: Duration = .seconds(5)

    /// The open input.
    public struct InUse: Equatable, Sendable {
        public let uid: String
        public let name: String
        public var selection: MicrophoneSelection

        public init(uid: String, name: String, selection: MicrophoneSelection = .inUse) {
            self.uid = uid; self.name = name; self.selection = selection
        }
    }

    /// What resolving again found.
    public enum Resolved: Equatable, Sendable {
        /// The input resolved to the open one, which is kept.
        case unchanged(MicrophoneSelection)
        /// Another input, opened or ready to open.
        case input(InUse)
        case failed
    }

    public enum Event: Equatable, Sendable {
        case timeout
        /// The open input was replaced.
        case reopened
        case openFailed
    }

    private enum Reason { case routeChanged, selectionChanged }

    public private(set) var input: InUse?
    public private(set) var selectedUID: String?
    /// When the input is due to be resolved again; nil when nothing is pending.
    public internal(set) var nextAttempt: Instant?
    private var delay = retryInitial
    private var reason: Reason?
    /// The route generation the open input was resolved at.
    private var routeGeneration: UInt64
    /// The wait before looking again for a missing picked microphone.
    public private(set) var selectionRetry = retryInitial
    /// The OS reports devices arriving, so an unlisted picked microphone's return arrives as a route change and
    /// needs no timed look. CoreAudio does.
    public var reportsNewDevices: Bool

    public init(selected: String?, routeGeneration: UInt64, reportsNewDevices: Bool = true) {
        selectedUID = selected; self.routeGeneration = routeGeneration; self.reportsNewDevices = reportsNewDevices
    }

    /// Whether a look is pending, which only an idle capture lets happen.
    public var isPending: Bool { nextAttempt != nil }

    /// The input opened, at a dictation's start or once a switch is made.
    public mutating func opened(_ opened: InUse, routeGeneration: UInt64, at now: Instant) {
        input = opened
        self.routeGeneration = routeGeneration
        recovered()
        afterResolving(now)
    }

    public mutating func closed() {
        input = nil
        recovered()
    }

    /// A newly picked microphone applies at the next open while closed, else at the next idle look.
    public mutating func requestSelection(_ selected: String?, at now: Instant) {
        guard selected != selectedUID else { return }
        selectedUID = selected
        guard input != nil else { return recovered() }
        nextAttempt = now
        delay = Self.retryInitial
        reason = .selectionChanged
    }

    /// Whether to resolve the input again now. A route change is noted whenever it is seen; it is acted on only
    /// while capture is idle.
    public mutating func poll(routeGeneration generation: UInt64, captureIdle: Bool, at now: Instant) -> Bool {
        guard input != nil else { return false }
        if generation != routeGeneration {
            routeGeneration = generation
            requestRouteCheck(at: now)
        }
        guard captureIdle, let nextAttempt, now >= nextAttempt else { return false }
        return true
    }

    /// Takes what resolving again found.
    public mutating func resolved(_ found: Resolved, captureIdle: Bool, at now: Instant) -> Event {
        switch found {
        case let .unchanged(selection):
            guard input != nil else {
                nextAttempt = now
                return .timeout
            }
            input?.selection = selection
            recovered()
            afterResolving(now)
            return .timeout
        case let .input(replacement) where captureIdle || input == nil:
            input = replacement
            recovered()
            afterResolving(now)
            return .reopened
        case .input:
            failed(now)
            return .timeout
        case .failed:
            if input == nil {
                recovered()
                return .openFailed
            }
            failed(now)
            return .timeout
        }
    }

    /// Resolves the input again at `at`. A pending selection change resolves it anyway, so it is left alone.
    private mutating func requestRouteCheck(at: Instant) {
        switch reason {
        case nil:
            reason = .routeChanged
            nextAttempt = at
            delay = Self.retryInitial
        case .routeChanged: nextAttempt = nextAttempt.map { min($0, at) } ?? at
        case .selectionChanged: break
        }
    }

    /// While the open input stands in for a picked microphone that would not open, or that is not listed where
    /// the OS doesn't report new devices, looks for it again with bounded backoff. A device change looks at once.
    private mutating func afterResolving(_ now: Instant) {
        let lookAgain = switch input?.selection {
        case .unopenable: true
        case .unlisted, .lidClosed: !reportsNewDevices
        case .inUse, nil: false
        }
        if lookAgain {
            requestRouteCheck(at: now + selectionRetry)
            selectionRetry = min(selectionRetry * 2, Self.retryMax)
        } else {
            selectionRetry = Self.retryInitial
        }
    }

    private mutating func failed(_ now: Instant) {
        nextAttempt = now + delay
        delay = min(delay * 2, Self.retryMax)
    }

    private mutating func recovered() {
        nextAttempt = nil
        delay = Self.retryInitial
        reason = nil
    }
}
