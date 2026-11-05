import AppKit

/// What apps do around a native editor: their own ⌘V handling, a re-render after each edit, a
/// slash-command menu at the caret, and an input method composition in progress.
@MainActor final class Behaviours {
    private var monitors: [Any] = []
    private var menu: NSPanel?
    private var observers: [NSObjectProtocol] = []
    private var pending: DispatchWorkItem?

    func reset() {
        monitors.forEach(NSEvent.removeMonitor); monitors = []
        observers.forEach(NotificationCenter.default.removeObserver); observers = []
        closeMenu(); pending?.cancel()
    }

    func composing() -> Bool { (NSApp.keyWindow?.firstResponder as? NSTextInputClient)?.hasMarkedText() ?? false }

    func apply(_ spec: Case, _ editor: Editor, window: NSWindow) {
        switch spec.reaction {
        case "paste-intercept": interceptPaste(editor)
        case "rerender": rerender(editor)
        case "slash-menu": openMenu(editor, window: window)
        case "ime": compose(window)
        default: break
        }
    }

    /// The app answers ⌘V itself, before the text view: it reads the plain text and inserts it a moment
    /// later, as apps that convert pastes do.
    private func interceptPaste(_ editor: Editor) {
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers?.lowercased() == "v",
                  let string = NSPasteboard.general.string(forType: .string) else { return event }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { editor.insert(string) }
            return nil
        } as Any)
    }

    /// The app rebuilds the editor's content from its state after each edit.
    private func rerender(_ editor: Editor) {
        var busy = false
        editor.onChange = { [weak self] in
            guard !busy else { return }
            self?.pending?.cancel()
            let work = DispatchWorkItem {
                busy = true; editor.rerender()
                DispatchQueue.main.async { busy = false }
            }
            self?.pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
        }
    }

    /// A "/" just typed opened a menu at the caret, in a child panel that never takes focus. It takes
    /// arrows, Return and Escape, and closes when the caret leaves the "/" or the "/" goes.
    private func openMenu(_ editor: Editor, window: NSWindow) {
        let anchor = (editor.text() as NSString).range(of: "/", options: .backwards).location
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 112), styleMask: [.nonactivatingPanel, .borderless],
                            backing: .buffered, defer: false)
        let list = NSStackView(views: ["Summarize", "Insert table", "Mention someone", "Add emoji"].map { NSTextField(labelWithString: $0) })
        list.orientation = .vertical; list.alignment = .leading; list.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        list.setAccessibilityRole(.list); list.setAccessibilityLabel("Commands")
        panel.contentView = list
        panel.backgroundColor = .windowBackgroundColor; panel.hasShadow = true
        var caret = window.convertToScreen(NSRect(x: 200, y: 120, width: 1, height: 1))
        if let client = window.firstResponder as? NSTextInputClient {
            let rect = client.firstRect(forCharacterRange: client.selectedRange(), actualRange: nil)
            if rect != .zero { caret = rect }
        }
        panel.setFrameOrigin(NSPoint(x: caret.minX, y: caret.maxY + 6))
        window.addChildWindow(panel, ordered: .above)
        menu = panel
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard self?.menu != nil, [36, 48, 53, 125, 126].contains(event.keyCode) else { return event }
            self?.closeMenu(); return nil
        } as Any)
        let check = { [weak self] in
            guard self?.menu != nil else { return }
            let slash = (editor.text() as NSString).range(of: "/", options: .backwards).location
            if slash != anchor || (editor.caret().map { $0 != anchor + 1 } ?? false) { self?.closeMenu() }
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSTextView.didChangeSelectionNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { check() }
        })
        let previous = editor.onChange
        editor.onChange = { previous?(); check() }
    }

    private func closeMenu() {
        if let menu { menu.parent?.removeChildWindow(menu); menu.orderOut(nil) }
        menu = nil
    }

    /// Marked text at the caret, as a Japanese input method leaves it before the user commits.
    private func compose(_ window: NSWindow) {
        guard let client = window.firstResponder as? NSTextInputClient else { return }
        client.setMarkedText("にほんご", selectedRange: NSRange(location: 4, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    }
}
