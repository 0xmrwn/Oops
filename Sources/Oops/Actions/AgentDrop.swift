import AppKit
import OopsCore
import SwiftUI

/// An agent run's drop in the panel the features share: Fix's drop and its phases, with Actions' words, at the caret;
/// and, while the person works elsewhere, the same drop parked at the edge of their screen (`ParkedDropView`). It
/// holds the drop only while the run starts and while it works with the person in its field; parked, finished,
/// failed, held or ready, it only offers something, so Fix, Dictate or another action takes it over when pressed.
@MainActor final class AgentDrop {
    private let owner: DropOwner
    private let locate: @MainActor (AXUIElement) async -> CapsulePlacement.Geometry?
    /// Whether the run is at work where the person is (or starting), which holds the drop.
    var busy: () -> Bool = { false }
    /// Whether the run is away from its field, or leaving it: its drop gives way to any feature's.
    var away: () -> Bool = { false }
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
    /// The drop came up, changed or went: whether Escape and Return reach the run depends on it.
    var changed: () -> Void = {}
    private var panel: CapsulePanel { owner.panel }
    private var model: CapsuleModel { owner.panel.model }
    /// The working label the status shows, kept while the drop is placed so the latest step wins.
    private var label = ""
    /// The action's name, for the parked drop's close badge.
    var name = ""
    /// When the run began: its working drop's timer counts from here each time the drop comes back to it.
    var startedAt: Date?
    /// When the run last reported anything, so a drop that comes back to a quiet run comes back calm.
    var heard: Date?
    /// The screen the drop parked on, which it follows to another.
    private var parkedOn: CGRect?
    /// The ready drop folding back into the pill once it has said so for a while.
    private var folding: Task<Void, Never>?

    /// Wider than Fix's panel: a step names its query, host or skill, with the run's timer after it.
    static let size = CGSize(width: 468, height: CapsulePanel.standard.height)
    /// How long a result just in stays open in the pill before it folds; it never times out.
    static let readyOpen: Duration = .seconds(8)

    init(owner: DropOwner, locate: @escaping @MainActor (AXUIElement) async -> CapsulePlacement.Geometry?) {
        self.owner = owner; self.locate = locate
    }

    /// The run's drop is the one up, and still the run's.
    var inFront: Bool { owner.claimant == .agent && owner.shown == .agent && panel.isShown }
    var parked: Bool { inFront && model.parked != nil }
    /// The run's working drop is up at the caret: Escape cancels it.
    var working: Bool { inFront && model.parked == nil && model.phase == .working }
    /// The ready drop is up at the caret: Return puts it in, Escape parks it.
    var readyAtCaret: Bool { inFront && model.parked == nil && model.phase == .fixed && model.open != nil }
    /// A drop went away, the run's or another feature's.
    var idle: (() -> Void)? {
        get { owner.onIdle }
        set { owner.onIdle = newValue }
    }

    /// Where a parked drop goes: Dictate's drop position, the top for a drop by the text.
    static var parking: DictationDropPosition { DictationDropPosition.saved == .bottom ? .bottom : .top }

    /// The screen the person is working on, the one the pointer is on, in the placement's coordinates.
    static func workScreen() -> CGRect? {
        let point = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }),
              let primary = NSScreen.screens.first?.frame.maxY else { return nil }
        return CGRect(x: screen.frame.minX, y: primary - screen.frame.maxY, width: screen.frame.width, height: screen.frame.height)
    }

    func claim() -> Bool {
        let model = model, panel = panel
        let passive = { [weak model, weak self] in
            (model.map { [.fixed, .reverted, .failed, .copied, .pending].contains($0.phase) } ?? true) || self?.away() == true
        }
        guard owner.claim(.agent, busy: { [weak self] in self?.busy() ?? false }, passive: passive,
                          released: { [weak self] in self?.released() }, size: Self.size,
                          content: { AnyView(AgentDropView(model: model)) }) else { return false }
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

    /// The run's step at the field, placed where the field is now: it may have moved while the person was away. From
    /// the pill it flies back to the caret.
    func showStatus(_ label: String, element: AXUIElement, fallback: CapsulePlacement.Geometry) {
        self.label = label
        if working { return panel.show(.working, label: label) }
        guard claim() else { return }
        // A claim starts the drop afresh; the run hasn't, so its timer and pace carry on.
        model.startedAt = startedAt
        Task {
            let geometry = await locate(element) ?? fallback
            guard owner.claimant == .agent, busy() else { return }
            panel.cancelTimedHide()
            model.canRevert = false; model.canCancel = true
            model.startedAt = startedAt
            if let heard { model.activity(at: heard) }
            toCaret(geometry)
            panel.show(.working, label: self.label, geometry: geometry)
            panel.follow(element) { [locate] in await locate($0) ?? geometry }
            changed()
        }
    }

    /// The running drop flies to the pill at the screen's edge, or comes back there after another feature's drop.
    func park(_ label: String) {
        self.label = label
        if parked, model.phase == .working { return model.label = label }
        guard claim() else { return }
        panel.cancelTimedHide()
        model.canRevert = false; model.canCancel = true
        model.startedAt = startedAt
        if let heard { model.activity(at: heard) }
        model.parked = ParkedPill(name: name)
        toPark()
        panel.show(.working, label: label, cue: false)
        changed()
    }

    /// New words for the parked pill, which it shows when the pointer opens it; nothing if it isn't up.
    func parkedStatus(_ label: String) {
        self.label = label
        if parked, model.phase == .working { model.label = label }
    }

    /// Work that can't be cancelled: the run going back to its draft, open in the pill until `geometry` says where its
    /// caret is, then there.
    func showWorking(_ label: String, geometry: CapsulePlacement.Geometry?) {
        guard claim() else { return }
        panel.cancelTimedHide()
        model.canCancel = false
        if let geometry { toCaret(geometry) } else { model.parked = ParkedPill(name: name, open: true); toPark() }
        panel.show(.working, label: label, geometry: geometry)
        changed()
    }

    /// A sign of progress: the run's working drop quickens if it is up, at the caret or parked.
    func activity() {
        heard = Date()
        if inFront, model.phase == .working { model.activity() }
    }

    /// The write is under way: the working drop at the caret says so, and no longer cancels.
    func showWriting(_ label: String) {
        guard inFront else { return }
        model.canCancel = false
        if model.phase == .working { panel.show(.working, label: label) }
        changed()
    }

    func showDone(_ label: String, spoken: String, canRestore: Bool, geometry: CapsulePlacement.Geometry?, element: AXUIElement) {
        guard claim() else { return }
        panel.cancelTimedHide()
        model.canRevert = canRestore
        if let geometry { toCaret(geometry) }
        panel.show(.fixed, label: label, detail: canRestore ? "Undo puts the original back" : "", spoken: spoken, geometry: geometry)
        panel.hide(after: ResultTiming.seconds)
        if let geometry { panel.follow(element) { [locate] in await locate($0) ?? geometry } }
        changed()
    }

    /// The answer wasn't written: it waits in the drop to be copied, where the drop is (open, if parked).
    func showHeld(_ reason: String, label: String = "Not written", geometry: CapsulePlacement.Geometry?) {
        guard claim() else { return }
        panel.cancelTimedHide()
        if let geometry { toCaret(geometry) } else { model.parked?.open = true }
        panel.show(.pending, label: label, detail: reason, geometry: geometry)
        changed()
    }

    /// The ready result in the pill. `open`: the first time it shows, it opens to say so, with one glow, and folds
    /// after `readyOpen`. `cue`: the success sound, the first time it is announced. False while another feature holds
    /// the drop.
    func showReady(_ name: String, open: Bool, cue: Bool) -> Bool {
        guard claim() else { return false }
        panel.cancelTimedHide()
        model.open = { [weak self] in self?.open() }
        model.parked = ParkedPill(name: name, open: open)
        toPark()
        panel.show(.fixed, label: name + " is ready", detail: "Click to put the answer in its draft", cue: cue)
        if open { unfold() }
        changed()
        return true
    }

    /// The ready result at the caret of its field, which the person came back to: Return, a click or its cap puts it
    /// in. `still`: whether the run wants it there yet, once the field is located.
    func showReady(_ name: String, element: AXUIElement, fallback: CapsulePlacement.Geometry, still: @escaping () -> Bool) {
        let open = { [weak self] in self?.open() }
        Task {
            let geometry = await locate(element) ?? fallback
            // Claimed only now: the pill keeps its cap while the field is located.
            guard still(), claim() else { return }
            panel.cancelTimedHide()
            model.open = { open() }
            toCaret(geometry)
            panel.show(.fixed, label: name + " is ready · Return puts it in", detail: "Return puts the answer in its draft", cue: false,
                       geometry: geometry)
            panel.follow(element) { [locate] in await locate($0) ?? geometry }
            changed()
        }
    }

    /// False while another feature holds the drop. No `geometry`: in the pill, where the person is.
    func showFailure(_ failure: ActionFailure, geometry: CapsulePlacement.Geometry?) -> Bool {
        guard claim() else { return false }
        panel.cancelTimedHide()
        if let geometry { toCaret(geometry) } else { model.parked = ParkedPill(name: name, open: true); toPark() }
        panel.show(.failed, label: failure.label.text, detail: failure.message, remedy: failure.label.remedy, geometry: geometry)
        panel.hide(after: 8)
        changed()
        return true
    }

    /// Lets go of the drop, hiding the run's own.
    func yield() {
        folding?.cancel()
        owner.yield(.agent)
        changed()
    }

    /// The person moved to another screen: the parked drop follows.
    func followScreen() {
        guard parked, let screen = Self.workScreen(), screen != parkedOn else { return }
        toPark()
    }

    private func toCaret(_ geometry: CapsulePlacement.Geometry) {
        folding?.cancel()
        model.parked = nil
        panel.fly(geometry: geometry, fixed: nil)
    }

    private func toPark() {
        parkedOn = Self.workScreen()
        panel.fly(geometry: nil, fixed: Self.parking, anchor: parkedOn)
    }

    /// A moment after it opens, as the glass settles, the ready drop glows once; it folds after `readyOpen`.
    private func unfold() {
        folding?.cancel()
        folding = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self, model.parked != nil else { return }
            model.parked?.pulse += 1
            try? await Task.sleep(for: Self.readyOpen)
            guard !Task.isCancelled, model.parked != nil, model.phase == .fixed else { return }
            model.parked?.open = false
        }
    }

    #if DEBUG
    /// The drop as a lab run sees it: whose it is, its phase and its words, and whether it is parked.
    var state: [String: String] {
        ["drop": panel.isShown ? owner.shown?.name ?? "none" : "none", "dropPhase": String(describing: model.phase), "label": model.label,
         "detail": model.detail, "parked": parked ? "yes" : "no"]
    }
    #endif
}
