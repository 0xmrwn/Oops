import AppKit
import OopsCore
import SwiftUI

/// An agent run's drop in the panel the features share: Fix's drop and its phases, with Actions' words. It holds the
/// drop only while the run starts and while it works with the person in its field; a finished, failed, held or ready
/// drop only offers something, so Fix, Dictate or another action takes it over when pressed.
@MainActor final class AgentDrop {
    private let owner: DropOwner
    private let locate: @MainActor (AXUIElement) async -> CapsulePlacement.Geometry?
    /// Whether the run is at work where the person is (or starting), which holds the drop.
    var busy: () -> Bool = { false }
    var cancel: () -> Void = {}
    /// The ready drop's tap and button: back to the draft.
    var open: () -> Void = {}
    /// The ready drop's close badge: the result is thrown away.
    var discard: () -> Void = {}
    var copy: () -> Void = {}
    var restore: () -> Void = {}
    var retry: () -> Void = {}
    var openSettings: () -> Void = {}
    /// The run's drop went away, or another feature took it over.
    var released: () -> Void = {}
    /// The drop came up, changed or went: whether Escape can cancel depends on it.
    var changed: () -> Void = {}
    private var panel: CapsulePanel { owner.panel }
    private var model: CapsuleModel { owner.panel.model }
    /// The working label the status shows, kept while the drop is placed so the latest step wins.
    private var label = ""

    /// Wider than Fix's panel: a step names its query, host or skill.
    static let size = CGSize(width: 360, height: CapsulePanel.standard.height)

    init(owner: DropOwner, locate: @escaping @MainActor (AXUIElement) async -> CapsulePlacement.Geometry?) {
        self.owner = owner; self.locate = locate
    }

    /// The run's drop is the one up, and still the run's.
    var inFront: Bool { owner.claimant == .agent && owner.shown == .agent && panel.isShown }
    /// The run's working drop is up: Escape cancels it.
    var working: Bool { inFront && model.phase == .working }
    /// A drop went away, the run's or another feature's.
    var idle: (() -> Void)? {
        get { owner.onIdle }
        set { owner.onIdle = newValue }
    }

    func claim() -> Bool {
        let model = model, panel = panel
        let passive = { [weak model] in model.map { [.fixed, .reverted, .failed, .copied, .pending].contains($0.phase) } ?? true }
        guard owner.claim(.agent, busy: { [weak self] in self?.busy() ?? false }, passive: passive,
                          released: { [weak self] in self?.released() }, size: Self.size,
                          content: { AnyView(EyesDropView(model: model)) }) else { return false }
        model.cancel = { [weak self] in self?.cancel() }
        model.revert = { [weak self] in self?.restore() }
        model.copy = { [weak self, weak panel] in
            self?.copy()
            if let panel, panel.isShown, panel.model.phase == .pending { panel.confirmCopy() }
        }
        model.retry = { [weak self] in self?.retry() }
        model.openSettings = { [weak self] in self?.openSettings() }
        model.dismiss = { [weak self, weak panel] in
            if panel?.model.open != nil { self?.discard() } else { panel?.hide() }
        }
        model.words = .actions
        model.canRevert = false; model.canCancel = true; model.narrates = true
        return true
    }

    /// The run's step at the field, placed where the field is now: it may have moved while the person was away.
    func showStatus(_ label: String, element: AXUIElement, fallback: CapsulePlacement.Geometry) {
        self.label = label
        if working { return panel.show(.working, label: label) }
        guard claim() else { return }
        Task {
            let geometry = await locate(element) ?? fallback
            guard owner.claimant == .agent, busy() else { return }
            panel.cancelTimedHide()
            model.canRevert = false; model.canCancel = true
            panel.show(.working, label: self.label, geometry: geometry)
            panel.follow(element) { [locate] in await locate($0) ?? geometry }
            changed()
        }
    }

    /// Work that can't be cancelled: the run going back to its draft.
    func showWorking(_ label: String, geometry: CapsulePlacement.Geometry?) {
        guard claim() else { return }
        panel.cancelTimedHide()
        model.canCancel = false
        panel.show(.working, label: label, geometry: geometry)
        changed()
    }

    /// The write is under way: the working drop at the caret no longer cancels.
    func stopCancelling() { if inFront { model.canCancel = false } }

    func showDone(_ name: String, elapsed: Duration, canRestore: Bool, geometry: CapsulePlacement.Geometry?, element: AXUIElement) {
        guard claim() else { return }
        panel.cancelTimedHide()
        model.canRevert = canRestore
        let time = elapsed.formatted(.time(pattern: .minuteSecond))
        panel.show(.fixed, label: name + " · " + time, detail: canRestore ? "Undo puts the original back" : "", spoken: name + " done", geometry: geometry)
        panel.hide(after: ResultTiming.seconds)
        if let geometry { panel.follow(element) { [locate] in await locate($0) ?? geometry } }
        changed()
    }

    /// The answer wasn't written: it waits in the drop to be copied.
    func showHeld(_ reason: String, label: String = "Not written", geometry: CapsulePlacement.Geometry?) {
        guard claim() else { return }
        panel.cancelTimedHide()
        panel.show(.pending, label: label, detail: reason, geometry: geometry)
        changed()
    }

    /// Where the person is, until they act on it or dismiss it. False while another feature holds the drop. `cue`: the
    /// first announcement plays the success sound; showing it again after another feature's drop doesn't.
    func showReady(_ name: String, geometry: CapsulePlacement.Geometry?, cue: Bool) -> Bool {
        guard claim() else { return false }
        panel.cancelTimedHide()
        model.open = { [weak self] in self?.open() }
        panel.show(.fixed, label: name + " is ready", detail: "Click to put the answer in its draft", cue: cue, geometry: geometry)
        changed()
        return true
    }

    /// False while another feature holds the drop.
    func showFailure(_ failure: ActionFailure, geometry: CapsulePlacement.Geometry?) -> Bool {
        guard claim() else { return false }
        panel.cancelTimedHide()
        panel.show(.failed, label: failure.label.text, detail: failure.message, remedy: failure.label.remedy, geometry: geometry)
        panel.hide(after: 8)
        changed()
        return true
    }

    /// Lets go of the drop, hiding the run's own.
    func yield() {
        owner.yield(.agent)
        changed()
    }

    #if DEBUG
    /// The drop as a lab run sees it: whose it is, its phase and its words.
    var state: [String: String] {
        ["drop": panel.isShown ? owner.shown?.name ?? "none" : "none", "dropPhase": String(describing: model.phase), "label": model.label, "detail": model.detail]
    }
    #endif
}
