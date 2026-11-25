import AppKit
import OopsCore

/// The centre as a field: its own key panel, the keys held while it comes up, the draft read before it takes them,
/// and the field the person was writing in given back its focus before anything runs.
@MainActor final class WheelFieldState {
    let model = WheelFieldModel()
    private(set) lazy var panel = WheelFieldPanel(model: model)
    /// The draft read as the wheel opened, for the run; nil until read, or once a run or the close took it.
    var draft: PreparedDraft?
    /// The field panel is up for this opening.
    var shown = false
    var opening: Task<Void, Never>?
    /// The wheel closed on a click elsewhere: the person moved on, and their new focus stays theirs.
    var clickedAway = false

    /// Whether closing gives the field the keys came from its focus back: after Escape or another shortcut, yes; after
    /// a click elsewhere, which chose a new focus, no.
    static func refocuses(shown: Bool, clickedAway: Bool) -> Bool { shown && !clickedAway }
    #if DEBUG
    /// Debug builds: an app treated as one where the centre can't type (`-DebugTypingUnavailable <bundle id>`).
    static let extraUnavailable: Set<String> = DebugFlags.typingUnavailable.map { [$0] } ?? []
    #else
    static let extraUnavailable: Set<String> = []
    #endif
}

extension WheelController {
    /// Whether the app in front keeps its field when Oops's field takes the keys for a moment.
    static func typingAvailable() -> Bool {
        WheelTyping.isAvailable(bundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                                unavailable: WheelTyping.unavailable.union(WheelFieldState.extraUnavailable))
    }

    /// Whether the centre takes typing for this opening.
    func typingHere() -> Bool {
        #if DEBUG
        if typingOff { return false }
        #endif
        return Self.typingAvailable()
    }

    /// Starts reading the draft, once: as the wheel is placed, and at the latest as its field opens.
    func prepareDraft() {
        if field.draft == nil { field.draft = actions.prepare() }
    }

    /// The draft for a run, which then owns it.
    func takeDraft() -> PreparedDraft? {
        defer { field.draft = nil }
        return field.draft
    }

    /// The centre has become a field: the keys wait in the tap while the field panel comes up over the centre and
    /// takes them, then go to it. A field that hasn't taken them within 300 ms gives up, and the ring comes back.
    func openField(placeholder: String) {
        prepareDraft()
        let model = field.model
        model.placeholder = placeholder
        model.ink = frame.ink
        model.text = ""
        field.clickedAway = false
        model.submit = { [weak self] text in self?.submitField(text) }
        model.cancel = { [weak self] in self?.close() }
        field.opening?.cancel()
        field.opening = Task { [weak self] in
            guard let self else { return }
            // The draft is read before the field takes the keys, when it can be within the field's own deadline: a
            // dormant Chromium field can take a second, and the keys wait in the tap meanwhile. The read already holds
            // its field, so the field coming up first doesn't change what it reads.
            var waited = 0
            while let draft = self.field.draft, !draft.isRead, waited < 30 {
                try? await Task.sleep(for: .milliseconds(10))
                guard !Task.isCancelled else { return }
                waited += 1
            }
            guard !Task.isCancelled, case .typing = self.wheel.level else { return }
            self.field.panel.place(hub: self.hub)
            let shownAt = CACurrentMediaTime()
            // Its words show only where the widening glass already is; each frame reveals more (`tick`).
            self.field.panel.window.alphaValue = self.motion.fieldReveal
            self.field.panel.show()
            self.field.shown = true
            waited = 0
            while !self.field.panel.isReady, waited < 30 {
                try? await Task.sleep(for: .milliseconds(10))
                guard !Task.isCancelled else { return }
                waited += 1
            }
            guard self.field.panel.isReady else { return self.fieldFailed() }
            self.keys?.replay()
            self.log(["wheel": "typing", "readyMs": "\(Int((CACurrentMediaTime() - shownAt) * 1000))"])
        }
    }

    private func fieldFailed() {
        log(["wheel": "typing-failed"])
        keys?.discardHeld()
        hideField()
        motion.endTyping()
        apply(wheel.typingFailed(at: CACurrentMediaTime()))
    }

    private func submitField(_ text: String) {
        let effects = wheel.submit(text)
        if effects.contains(where: { if case .run(.typed) = $0 { true } else { false } }) { learnedTyping() }
        apply(effects)
    }

    func hideField() {
        field.opening?.cancel()
        field.opening = nil
        guard field.shown else { return }
        field.shown = false
        field.panel.hide()
    }

    /// Whether a click lands in the field, which then has it.
    func fieldTakes(_ point: CGPoint) -> Bool {
        field.shown && WheelFieldPanel.frame(hub: hub).insetBy(dx: -4, dy: -4).contains(point)
    }

    /// A run the wheel chose, with the draft it read. From the field, the field it held the keys from gets them back
    /// first, its selection as it was.
    func startRun(_ invocation: ActionInvocation) {
        let draft = takeDraft()
        guard field.shown else { return report(actions.run(invocation, draft: draft)) }
        hideField()
        Task { [weak self] in
            await self?.refocus(draft)
            guard let self else { return }
            self.report(self.actions.run(invocation, draft: draft))
        }
    }

    /// The wheel closed. Without a run its read draft is let go, and a field gives the keys back.
    func endTyping(ran: Bool) {
        let back = WheelFieldState.refocuses(shown: field.shown, clickedAway: field.clickedAway)
        hideField()
        guard !ran, let draft = takeDraft() else { return }
        Task { [weak self] in
            if back { await self?.refocus(draft) }
            self?.actions.release(draft)
        }
    }

    private func refocus(_ draft: PreparedDraft?) async {
        guard let draft, let snapshot = try? await draft.snapshot() else { return }
        let back = await editor.refocus(snapshot)
        log(["wheel": "refocus", "back": back ? "yes" : "no", "strategy": "\(snapshot.strategy)"])
    }

    func report(_ run: Task<ActionOutcome, Never>?) {
        #if DEBUG
        onRun?(run)
        #endif
    }
}
