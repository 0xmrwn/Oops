import AppKit
import Carbon
import OopsCore
import QuartzCore

/// The Actions wheel: opens on the Actions shortcut by the caret, where Fix's drop would be, takes the arrows and
/// the pointer while it is open, and hands what is chosen to the Actions session. It draws in its own window but
/// holds the drop while open, so it waits for Fix's and Dictate's drops and they wait for it.
@MainActor final class WheelController: NSObject {
    typealias MakeKeys = @MainActor (_ chords: [WheelChord], _ deliver: @escaping @MainActor (WheelInput) -> Bool) throws -> WheelKeys?

    private let actions: ActionSession
    private let drop: DropOwner
    private let editor: EditorAccess
    /// The saved actions, read at each opening.
    var library: @MainActor () -> ActionLibrary
    /// Every shortcut Oops has registered, the Actions one included: their keys go on to their handlers.
    private let chords: @MainActor () -> [Shortcut]
    private let makeKeys: MakeKeys
    /// Says in the status line why the wheel didn't open.
    var refused: (_ message: String) -> Void = { _ in }

    private(set) var wheel = Wheel()
    private(set) var motion = WheelMotion()
    let frame = WheelFrame()
    private(set) lazy var panel = WheelPanel(frame: frame)
    /// The last opening's tap, kept while it drains.
    private(set) var keys: WheelKeys?
    private var link: CADisplayLink?
    /// Wakes the paused display link for the wheel's next wait (names after the linger, a ring's bloom).
    private var dozing: Timer?
    /// Drives the wheel's waits until the display link does: an arrow pressed at once still commits.
    private var waiting: Timer?
    private var locating: Task<Void, Never>?
    private var closing: Task<Void, Never>?
    /// The window is up for this opening (`shown` lasts until its motion has gone).
    private(set) var placed = false, shown = false
    private(set) var hub = CGPoint.zero
    /// Motion that came before the window was up, played once it is.
    private var queued: [WheelEffect] = []
    private var pressed: WheelHit?
    private(set) var petals: [ActionPlace: WheelPetal] = [:]
    private var ring: [ActionPlace: WheelPetal] = [:]
    private var ringName = ""
    /// Where the restore petal is, for this opening.
    private(set) var restoring: ActionPlace?
    /// What the restore petal puts back: opening hides the result drop, which ends the record it kept.
    private var kept: ActionSession.Written?
    private var lastTick = 0.0, openedAt = 0.0, placedAt = 0.0, closedAt = 0.0, settledTold = false
    /// Frames since the window came up and the longest gap between two, for the settled line.
    private var frames = 0, longest = 0.0
    #if DEBUG
    /// Every effect and refusal, for actions.jsonl; and each run the wheel starts.
    var onEvent: (([String: String]) -> Void)?
    var onRun: ((Task<ActionOutcome, Never>?) -> Void)?
    #endif

    init(actions: ActionSession, drop: DropOwner, editor: EditorAccess, library: @escaping @MainActor () -> ActionLibrary,
         chords: @escaping @MainActor () -> [Shortcut], makeKeys: MakeKeys? = nil) {
        self.actions = actions; self.drop = drop; self.editor = editor; self.library = library; self.chords = chords
        self.makeKeys = makeKeys ?? { try WheelKeys(chords: $0, deliver: $1) }
        super.init()
        frame.choose = { [weak self] in self?.click($0) }
    }

    var isOpen: Bool { wheel.isOpen }

    /// The Actions shortcut's press: opens, or closes when open. Its release does nothing, so tapped and held are one.
    func shortcut() {
        if wheel.isOpen { close() } else { open() }
    }

    /// Another feature's shortcut was pressed: the wheel steps aside, writing nothing.
    func yield() {
        guard wheel.isOpen else { return }
        log(["wheel": "yield"])
        close()
    }

    func close() { apply(wheel.close()) }

    private func open() {
        if actions.isBusy { return refuse(nil, "busy") }
        if let holder = drop.holder {
            // Its own drop at work says nothing; Fix's or Dictate's says why, as Dictate does in their place.
            return holder == .actions ? refuse(nil, "held") : refuse(CorrectionSession.dropTaken, holder == .fix ? "fix" : "dictate")
        }
        // Another app's secure input hides every key from a tap: the wheel would hear nothing.
        if IsSecureEventInputEnabled() { return refuse("Another app is protecting what you type, so Actions can’t open.", "secure") }
        keys?.remove()
        do { keys = try makeKeys(chords().map(Self.chord)) { [weak self] in self?.deliver($0) ?? false } } catch {
            keys = nil
            return refuse("Allow Oops in \(AccessibilityPermission.paneName) to use Actions.", "tap")
        }
        var restorable: UUID?
        if actions.canRestore, case let .saved(action, _)? = actions.last { restorable = action.id }
        kept = restorable == nil ? nil : actions.written
        guard drop.hold(.actions, busy: { [weak self] in self?.wheel.isOpen == true }) else {
            keys?.remove()
            return refuse(nil, "held")
        }
        if shown { finish() }
        let library = library()
        frame.widths = [:]
        restoring = library.actions.first { $0.id == restorable }?.place
        petals = Dictionary(library.actions.map { action in
            let restore = action.place == restoring
            return (action.place, petal(action.place, restore ? "Restore" : action.name, restore ? "arrow.uturn.backward" : action.symbol))
        }) { a, _ in a }
        ring = [:]; queued = []; pressed = nil; settledTold = false
        motion = WheelMotion(reduceMotion: Self.reduceMotion)
        openedAt = CACurrentMediaTime()
        apply(wheel.open(library, restorable: restorable, at: openedAt))
        let timer = Timer(timeInterval: 0.016, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.advance() }
        }
        RunLoop.main.add(timer, forMode: .common)
        waiting = timer
        // The tap is already live: an arrow pressed while the field is read is taken, not typed.
        locating = Task { [weak self] in await self?.locate() }
    }

    private func refuse(_ message: String?, _ reason: String) {
        if let message { refused(message) }
        log(["wheel": "refused", "reason": reason])
    }

    /// Where the wheel goes and in which ink, read at most 150 ms so no glyph ever shows in the wrong tone.
    private func locate() async {
        let editor = editor
        let found = await Self.reading(within: .milliseconds(150)) { (try? await editor.focusedTone()).map { Spot(geometry: $0.geometry, style: $0.style) } }
        guard !Task.isCancelled, wheel.isOpen else { return }
        hub = WheelPlacement.hub(found?.geometry, screens: WheelPanel.screens)
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast || EyesDropView.forced.contains("increase-contrast")
        let transparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency || EyesDropView.forced.contains("reduce-transparency")
        let dark = DebugFlags.capsuleAppearance.map { $0 == "dark" }
            ?? (NSApplication.shared.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        let web = found?.geometry.ancestors.contains { $0.role == "AXWebArea" } == true
        frame.ink = WheelInk(page: found?.style, web: web, systemDark: dark, increaseContrast: contrast, reduceTransparency: transparency)
        frame.increaseContrast = contrast; frame.reduceTransparency = transparency
        show()
        log(["wheel": "placed", "hub": "\(Int(hub.x)),\(Int(hub.y))", "found": found == nil ? "no" : "yes", "web": web ? "yes" : "no",
             "ink": frame.ink.plain ? "plain" : frame.ink.dark ? "dark" : "light",
             "strategy": CapsulePlacement.place(found?.geometry, envelope: CGSize(width: WheelLayout.drop, height: WheelLayout.envelope.height),
                                                screens: WheelPanel.screens).strategy.rawValue])
    }

    private func show() {
        waiting?.invalidate(); waiting = nil
        panel.place(hub: hub)
        let now = CACurrentMediaTime()
        placedAt = now; lastTick = now; frames = 0; longest = 0
        placed = true; shown = true
        panel.window.orderFrontRegardless()
        motion.open()
        // A ring entered before the window was up blooms now, and says so with the window on screen.
        queued.forEach(perform)
        queued = []
        frame.motion = motion
        let link = panel.window.contentView!.displayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
        apply(wheel.placed(at: now))
        if let opening = openingAnnouncement() { announce(opening) }
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        let dt = min(now - lastTick, 1.0 / 20) * Self.pace
        frames += 1; longest = max(longest, now - lastTick)
        lastTick = now
        apply(wheel.advance(to: now))
        motion.step(dt)
        frame.motion = motion
        if !settledTold, motion.settled {
            settledTold = true
            log(["wheel": "settled", "petals": "\(motion.root.filter { !$0.leaving }.count)",
                 "ms": "\(Int((now - openedAt) * 1000))", "bloomMs": "\(Int((now - placedAt) * 1000))",
                 "frames": "\(frames)", "longestMs": "\(Int(longest * 1000))"])
        }
        if !wheel.isOpen, motion.gone {
            log(["wheel": "gone", "ms": "\(Int((now - closedAt) * 1000))"])
            finish()
        } else if wheel.isOpen, closing == nil, motion.resting {
            doze(until: wheel.nextDue, now: now)
        }
    }

    /// Nothing moves: the display link stops drawing identical frames until input or the wheel's next wait.
    private func doze(until due: TimeInterval?, now: TimeInterval) {
        guard let link, !link.isPaused else { return }
        link.isPaused = true
        log(["wheel": "doze", "until": due.map { "\(Int(($0 - openedAt) * 1000))" } ?? ""])
        guard let due else { return }
        let timer = Timer(timeInterval: max(0, due - now), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.wake() }
        }
        RunLoop.main.add(timer, forMode: .common)
        dozing = timer
    }

    /// Something may move again: the display link draws from now.
    private func wake() {
        dozing?.invalidate(); dozing = nil
        guard let link, link.isPaused else { return }
        lastTick = CACurrentMediaTime()
        link.isPaused = false
    }

    private func advance() { apply(wheel.advance(to: CACurrentMediaTime())) }

    /// The window goes once nothing is left to draw, or at once when a new opening needs it.
    private func finish() {
        closing?.cancel(); closing = nil
        dozing?.invalidate(); dozing = nil
        link?.invalidate(); link = nil
        if shown { panel.window.orderOut(nil) }
        shown = false; placed = false
        motion = WheelMotion()
        frame.motion = motion
    }

    // MARK: Input

    /// A key or the pointer from the tap; true when a mouse-down stops here.
    private func deliver(_ input: WheelInput) -> Bool {
        let now = CACurrentMediaTime()
        var stop = false
        switch input {
        case let .key(.arrow(arrow), down, isRepeat):
            if !down { apply(wheel.release(arrow, at: now)) } else if !isRepeat { apply(wheel.press(arrow, at: now)) }
        case .key(.escape, true, _):
            close()
        case .key(.leave, true, _):
            log(["wheel": "leave"])
            close()
        case .key:
            // Return, typing and the rest are taken so the draft never gets them, and do nothing here.
            break
        case let .mouseMoved(point):
            if case let .place(place)? = hit(point) { apply(wheel.hover(place, at: now)) } else { apply(wheel.hover(nil, at: now)) }
        case let .mouseDown(point):
            pressed = hit(point)
            stop = pressed != nil
            // A click anywhere else is the person moving on: the wheel closes and the click goes through.
            if !stop {
                log(["wheel": "clickedAway", "at": "\(Int(point.x)),\(Int(point.y))"])
                close()
            }
        case let .mouseUp(point):
            if case let .place(place)? = pressed, hit(point) == pressed { apply(wheel.click(place, at: now)) }
            pressed = nil
        }
        advance()
        wake()
        return stop
    }

    private func hit(_ point: CGPoint) -> WheelHit? { placed ? motion.hit(panel.canvasPoint(point)) : nil }

    /// VoiceOver's button for a petal.
    private func click(_ place: ActionPlace) {
        let now = CACurrentMediaTime()
        apply(wheel.click(place, at: now))
        advance()
        wake()
    }

    // MARK: Effects

    private func apply(_ effects: [WheelEffect]) {
        guard !effects.isEmpty else { return }
        // The centre shows the chosen symbol a moment before everything goes back in.
        let selecting = effects.contains { if case .select = $0 { true } else { false } }
        for effect in effects {
            log(Self.entry(effect))
            switch effect {
            case let .run(invocation):
                endOpen()
                let run = actions.run(invocation)
                #if DEBUG
                onRun?(run)
                #endif
            case .restore:
                endOpen()
                if let kept { actions.remember(kept) }
                let run = actions.restore()
                if run == nil { actions.remember(nil) }
                #if DEBUG
                onRun?(run)
                #endif
            case .close:
                endOpen()
                kept = nil
                retract(after: selecting ? 0.12 : 0)
            case let .bloomChoices(places):
                // The ring is known now; by the time a queued bloom plays, the wheel may have moved on.
                if case let .choices(action) = wheel.level {
                    ringName = action.choice?.name ?? action.name
                    ring = Dictionary(places.compactMap { place in action.choice?.values[place].map { (place, petal(place, $0, nil)) } }) { a, _ in a }
                }
                enqueue(effect)
            default:
                enqueue(effect)
            }
        }
    }

    private func enqueue(_ effect: WheelEffect) {
        if placed {
            perform(effect)
            wake()
        } else {
            queued.append(effect)
        }
    }

    private func perform(_ effect: WheelEffect) {
        switch effect {
        case let .bloom(places): motion.bloom(places.compactMap { petals[$0] })
        case .skipBloom: motion.skipBloom()
        case let .point(place): motion.setLive(place)
        case .showNames: motion.showNames()
        case let .select(place, symbol): motion.select(place, symbol: symbol)
        case let .bloomChoices(places):
            let pills = places.compactMap { ring[$0] }
            motion.bloomChoices(pills)
            announce(WheelAnnouncement.choices(ringName, pills))
        case .run, .restore, .close: break
        }
    }

    /// The wheel is closed: the tap only lets go of the keys it took, and the hold ends with `isOpen`.
    private func endOpen() {
        waiting?.invalidate(); waiting = nil
        locating?.cancel(); locating = nil
        pressed = nil
        queued = []
        keys?.drain()
    }

    private func retract(after delay: Double) {
        guard shown else { return }
        closing?.cancel()
        guard delay > 0 else { return closeMotion() }
        closing = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay / Self.pace))
            guard !Task.isCancelled else { return }
            self?.closeMotion()
        }
    }

    private func closeMotion() {
        closedAt = CACurrentMediaTime()
        motion.close()
        wake()
    }
}
