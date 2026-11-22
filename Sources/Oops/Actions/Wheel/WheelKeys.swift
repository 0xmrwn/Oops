import AppKit
import OopsCore

/// What the tap hands the wheel: a key it takes or lets through, or the pointer in screen points (top-left origin).
enum WheelInput {
    case key(WheelKey, down: Bool, isRepeat: Bool)
    case mouseMoved(CGPoint), mouseDown(CGPoint), mouseUp(CGPoint)
}

/// Keys and the pointer while the wheel is open, through an event tap that exists only then. The wheel's window
/// never becomes key and the app in front keeps its focus, so the wheel hears its keys here and the draft never gets
/// them; hover and clicks come the same way, as a panel that never activates gets no reliable mouse tracking.
@MainActor final class WheelKeys {
    /// After closing, how long the tap waits for the keys it took to come up, how often it then looks whether they
    /// are still held, and the most it ever stays.
    struct Drain {
        var first: Duration = .seconds(1), poll: Duration = .milliseconds(250), limit: Duration = .seconds(10)
    }

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var live = false
    private let chords: [WheelChord]
    private let deliver: @MainActor (WheelInput) -> Bool
    private let keyIsDown: @MainActor (Int64) -> Bool
    private let timing: Drain
    /// Key codes whose key-down stopped here: their key-up stops here too, even after the wheel closed.
    private var taken: Set<Int64> = []
    /// A mouse-down that stopped here: its mouse-up stops too.
    private var mouseTaken = false
    private var draining = false
    private var drainEnd: Task<Void, Never>?
    #if DEBUG
    /// Key events this tap handled, for the probe that asks whether posted events reach it.
    private(set) var handledCount = 0
    #endif

    var isLive: Bool { live }

    /// Taken keys and the pointer go to `deliver`, which answers whether a mouse-down stops here. `chords` are every
    /// shortcut Oops has registered: they always go on to their handlers. Without `listening` no tap is made and only
    /// `handle` feeds it, as tests do.
    init(chords: [WheelChord], deliver: @escaping @MainActor (WheelInput) -> Bool, listening: Bool = true,
         keyIsDown: @escaping @MainActor (Int64) -> Bool = { CGEventSource.keyState(.hidSystemState, key: CGKeyCode($0)) },
         drain timing: Drain = Drain()) throws {
        self.chords = chords
        self.deliver = deliver
        self.keyIsDown = keyIsDown
        self.timing = timing
        live = true
        guard listening else { return }
        let kinds: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .mouseMoved, .leftMouseDragged,
                                    .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp]
        let mask = kinds.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
                                callback: { _, type, event, context in
                                    guard let context else { return Unmanaged.passUnretained(event) }
                                    // The source is on the main run loop, so this runs on the main thread.
                                    let stop = MainActor.assumeIsolated {
                                        Unmanaged<WheelKeys>.fromOpaque(context).takeUnretainedValue().handle(type, event)
                                    }
                                    return stop ? nil : Unmanaged.passUnretained(event)
                                }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else { throw CorrectionError.message("Allow Oops in \(AccessibilityPermission.paneName) to use Actions.") }
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    isolated deinit { remove() }

    /// The tap's own path, which debug triggers call with events they built. True when the event stops here.
    func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        // The swap's and capture's own keys, and whatever arrives once the tap is gone.
        guard live, event.getIntegerValueField(.eventSourceUserData) != KeyboardGate.marker else { return false }
        #if DEBUG
        if type == .keyDown || type == .keyUp { handledCount += 1 }
        #endif
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        if draining { return drained(type, code) }
        switch type {
        case .keyDown:
            let key = WheelKey.classify(keyCode: code, flags: event.flags, characters: Self.characters(event), chords: chords)
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            switch key {
            // Oops's shortcuts go on to their handlers, which close the wheel; other ⌘ and ⌃ shortcuts close it and go on.
            case .pass: return false
            case .leave:
                _ = deliver(.key(key, down: true, isRepeat: isRepeat))
                return false
            default:
                // Taken before it is heard: a key that closes the wheel still has its key-up stopped.
                taken.insert(code)
                _ = deliver(.key(key, down: true, isRepeat: isRepeat))
                return true
            }
        case .keyUp:
            // Keys held from before the wheel opened, and the chord's own, come up where they went down.
            guard taken.remove(code) != nil else { return false }
            if let arrow = WheelArrow(keyCode: code) { _ = deliver(.key(.arrow(arrow), down: false, isRepeat: false)) }
            return true
        case .mouseMoved, .leftMouseDragged:
            _ = deliver(.mouseMoved(event.location))
            return false
        case .leftMouseDown, .rightMouseDown:
            mouseTaken = deliver(.mouseDown(event.location))
            return mouseTaken
        case .leftMouseUp, .rightMouseUp:
            let stop = mouseTaken
            mouseTaken = false
            if stop { _ = deliver(.mouseUp(event.location)) }
            return stop
        default:
            return false
        }
    }

    /// The wheel closed: only what it took still stops here, its key-ups and the repeats of a key still held, so
    /// none of it reaches the draft. The tap goes once they are up, a key-up missed or not, and never stays past
    /// the drain's limit.
    func drain() {
        guard live, !draining else { return }
        draining = true
        guard !taken.isEmpty || mouseTaken else { return remove() }
        let timing = timing, started = ContinuousClock.now
        drainEnd = Task { [weak self] in
            try? await Task.sleep(for: timing.first)
            while !Task.isCancelled, let self, self.live {
                if !self.taken.contains(where: self.keyIsDown) || started.duration(to: .now) >= timing.limit { return self.remove() }
                try? await Task.sleep(for: timing.poll)
            }
        }
    }

    func remove() {
        drainEnd?.cancel()
        drainEnd = nil
        taken = []
        mouseTaken = false
        live = false
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        CFMachPortInvalidate(tap)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        self.tap = nil
        source = nil
    }

    private func drained(_ type: CGEventType, _ code: Int64) -> Bool {
        let stop = switch type {
        // A key still held repeats: its repeats stop here too.
        case .keyDown: taken.contains(code)
        case .keyUp: taken.remove(code) != nil
        case .leftMouseUp, .rightMouseUp: mouseTaken
        default: false
        }
        if type == .leftMouseUp || type == .rightMouseUp { mouseTaken = false }
        if taken.isEmpty, !mouseTaken { remove() }
        return stop
    }

    private static func characters(_ event: CGEvent) -> String {
        var length = 0
        var units = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(maxStringLength: 8, actualStringLength: &length, unicodeString: &units)
        return String(utf16CodeUnits: units, count: length)
    }
}
