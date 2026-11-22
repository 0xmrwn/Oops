import AppKit
import OopsCore
import SwiftUI

/// What the Actions drop shows.
enum ActionDropState: Equatable {
    case working(String)
    case done(String, seconds: Double, canRestore: Bool)
    /// The answer couldn't be written (the draft or focus changed meanwhile): it waits in the drop to be copied.
    case held(String)
    case restored
    case failed(ActionFailure)
}

/// What the drop's buttons do, set once by the session.
struct ActionDropControls {
    var cancel: @MainActor () -> Void = {}
    var restore: @MainActor () -> Void = {}
    var copy: @MainActor () -> Void = {}
    var retry: @MainActor () -> Void = {}
    var openSettings: @MainActor () -> Void = {}
    /// The drop went away, or another feature took it: nothing it offered can be used any more.
    var ended: @MainActor () -> Void = {}
}

/// The drop as an action sees it: claimed for a run, told each state, and let go.
@MainActor protocol ActionDrop: AnyObject {
    var controls: ActionDropControls { get set }
    /// Takes the drop for Actions; false while another feature holds it.
    func claim(busy: @escaping () -> Bool) -> Bool
    /// Shows `state` by the draft at `geometry` (nil keeps the drop's spot), following `element` as its window moves.
    func show(_ state: ActionDropState, geometry: CapsulePlacement.Geometry?, element: AXUIElement?)
    /// Off while the swap commits.
    var canCancel: Bool { get set }
    /// Whether the done drop still offers to restore.
    var canRestore: Bool { get set }
    func leave()
}

/// The Actions drop in the panel the features share: Fix's drop and its phases, with Actions' labels and buttons.
@MainActor final class ActionDropOwner: ActionDrop {
    private let owner: DropOwner
    private let locate: @MainActor (AXUIElement) async -> CapsulePlacement.Geometry?
    var controls = ActionDropControls()
    private var panel: CapsulePanel { owner.panel }
    private var model: CapsuleModel { owner.panel.model }
    /// The shared model is Actions' to change only while its view is the one in the panel.
    private var showing: Bool { owner.shown == .actions }

    init(owner: DropOwner, locate: @escaping @MainActor (AXUIElement) async -> CapsulePlacement.Geometry?) {
        self.owner = owner; self.locate = locate
    }

    func claim(busy: @escaping () -> Bool) -> Bool {
        let model = model, panel = panel
        // A finished drop only offers its button: Fix or Dictate, pressed meanwhile, takes it over. A held answer
        // waits to be copied, as Fix's does.
        let passive = { [weak model] in !busy() && (model.map { [.fixed, .reverted, .failed, .copied].contains($0.phase) } ?? true) }
        guard owner.claim(.actions, busy: busy, passive: passive,
                         released: { [weak self] in self?.controls.ended() }, content: { AnyView(EyesDropView(model: model)) }) else { return false }
        model.cancel = { [weak self] in self?.controls.cancel() }
        model.revert = { [weak self] in self?.controls.restore() }
        model.copy = { [weak self] in self?.copy() }
        model.retry = { [weak self] in self?.controls.retry() }
        model.openSettings = { [weak self] in self?.controls.openSettings() }
        model.dismiss = { [weak panel] in panel?.hide() }
        model.canRevert = false; model.canCancel = true
        return true
    }

    func show(_ state: ActionDropState, geometry: CapsulePlacement.Geometry?, element: AXUIElement?) {
        guard showing else { return }
        panel.cancelTimedHide()
        model.canRevert = false
        switch state {
        case .working(let name):
            panel.show(.working, label: name + "…", geometry: geometry)
        case .done(let name, let seconds, let canRestore):
            model.canRevert = canRestore
            panel.show(.fixed, label: name + " · " + TestEditorModel.seconds(seconds), detail: canRestore ? "Undo puts the original back" : "",
                       spoken: name + " done in " + CorrectionSession.spoken(seconds), geometry: geometry)
            panel.hide(after: ResultTiming.seconds)
        case .held(let reason):
            panel.show(.pending, label: "Not written", detail: reason, geometry: geometry)
        case .restored:
            panel.show(.reverted, label: "Restored", geometry: geometry)
            panel.hide(after: ResultTiming.seconds)
        case .failed(let failure) where failure.reason == .partial:
            // Part of the draft changed and stayed: the drop keeps the answer to copy, as a held one does.
            panel.show(.pending, label: failure.label.text, detail: failure.message, geometry: geometry)
        case .failed(let failure):
            panel.show(.failed, label: failure.label.text, detail: failure.message, remedy: failure.label.remedy, geometry: geometry)
            panel.hide(after: 8)
        }
        if let element, let geometry { panel.follow(element) { [locate] in await locate($0) ?? geometry } }
    }

    var canCancel: Bool {
        get { model.canCancel }
        set { if showing { model.canCancel = newValue } }
    }
    var canRestore: Bool {
        get { showing && model.canRevert }
        set { if showing { model.canRevert = newValue } }
    }
    func leave() { if showing { panel.hide() } }

    /// Copies the held answer, then the drop says so as Fix's does.
    private func copy() {
        controls.copy()
        if panel.isShown, model.phase == .pending { panel.confirmCopy() }
    }
}

extension ActionFailure {
    /// A few words for the drop and what would help; the message stays in its tooltip.
    var label: (text: String, remedy: CapsuleModel.Remedy?) {
        switch reason {
        case .empty: ("Empty draft", nil)
        case .tooLong: ("Too long", nil)
        case .secure: ("Password field", nil)
        case .capture: AccessibilityPermission.granted ? ("Can’t edit here", nil) : ("Not allowed", .settings)
        case .agentRun: ("Agent not ready", nil)
        case .noModel: ("No model", .settings)
        case .offline: ("No connection", .retry)
        case .slow: ("Took too long", .retry)
        case .signIn: ("Signed out", .settings)
        case .limit: ("Limit reached", .settings)
        case .setup: ("Check provider", .settings)
        case .model: ("Couldn’t run", .retry)
        case .output: ("No answer", .retry)
        case .restore: ("Couldn’t restore", nil)
        case .partial: ("Partly written", nil)
        }
    }
}
