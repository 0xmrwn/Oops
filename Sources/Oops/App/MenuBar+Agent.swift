import AppKit
import OopsCore

/// An agent run in the menu bar: the eyes carry a ring while it runs and a dot once its result is ready, and the
/// menu says what it is doing, with Cancel, or offers the result, with Discard. Hidden while no run is under way.
extension MenuBar {
    private enum Tag { static let state = 0xA9E1, action = 0xA9E2, separator = 0xA9E3 }

    func installAgentItems(in menu: NSMenu) {
        let state = NSMenuItem(title: "", action: nil, keyEquivalent: ""), action = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        let separator = NSMenuItem.separator()
        for (item, tag) in [(separator, Tag.separator), (state, Tag.state), (action, Tag.action)] {
            item.tag = tag; item.isHidden = true
            menu.addItem(item)
        }
    }

    /// Shows the run's items for what it is doing now; called as the menu opens and while it is open.
    func updateAgentItems() {
        guard let menu = statusItem.menu, let state = menu.item(withTag: Tag.state), let action = menu.item(withTag: Tag.action) else { return }
        let run = agent(), mark = run?.flow.mark ?? .none
        for tag in [Tag.state, Tag.action, Tag.separator] { menu.item(withTag: tag)?.isHidden = mark == .none }
        guard let run, mark != .none else { return }
        state.image = Self.symbol(run.symbol)
        action.target = self
        switch mark {
        case .running:
            state.title = run.name + " · " + run.stepLabel
            state.action = nil
            action.title = "Cancel " + run.name
            action.action = #selector(cancelAgent)
            action.image = Self.symbol("xmark.circle")
        case .ready:
            state.title = run.name + " is ready"
            state.target = self; state.action = #selector(actOnAgent)
            action.title = "Discard result"
            action.action = #selector(discardAgent)
            action.image = Self.symbol("trash")
        case .none: break
        }
        if #available(macOS 27, *) { [state, action].forEach { $0.preferredImageVisibility = .visible } }
    }

    /// The run changed: the eyes show its mark, and an open menu its state.
    func agentChanged() {
        let run = agent(), mark = run?.flow.mark ?? .none
        if let button = statusItem.button {
            button.image = MenuBarEyes.image(mark)
            let label = switch mark {
            case .none: "Oops"
            case .running: "Oops, \(run?.name ?? "action") running"
            case .ready: "Oops, \(run?.name ?? "action") ready"
            }
            button.toolTip = label
            button.setAccessibilityLabel(label)
        }
        if menuOpen { updateAgentItems() }
    }

    // Lets the menu close before the run takes focus back to its draft.
    @objc private func actOnAgent() { Task { await Task.yield(); agent()?.act() } }
    @objc private func discardAgent() { agent()?.dismiss() }
    @objc private func cancelAgent() { agent()?.cancel() }
}
