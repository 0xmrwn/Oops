#if DEBUG
import AppKit
import OopsCore

/// Lab triggers for the Actions wheel. Carbon never hears posted keys, so the shortcut has a trigger of its own;
/// keys and the pointer are built as real events and handed to the wheel's tap through its own path, so everything
/// after the tap is what a person's keys would do. Each effect, refusal and outcome is a line in actions.jsonl.
@MainActor extension AppDelegate {
    func observeWheelTriggers(_ on: (String, @escaping @MainActor ([String: String]) -> Void) -> Void) {
        wheel.onEvent = { Self.record($0, to: "actions.jsonl") }
        wheel.onRun = { [weak self] in self?.recordAction($0) }
        on("wheel-shortcut") { [weak self] _ in if Self.labIsInFront() { self?.wheel.shortcut() } }
        on("wheel-key") { [weak self] info in
            guard let self, let name = info["key"], self.overLab() else { return }
            Task { await self.key(name, phase: info["phase"] ?? "tap") }
        }
        // `up+right,40,up-,30,right-`: presses, waits in milliseconds and releases (`open` is the shortcut), in one
        // go, so a gesture's timing doesn't depend on how fast triggers arrive.
        on("wheel-keys") { [weak self] info in
            guard let self, let spec = info["spec"], self.overLab() else { return }
            Task { await self.keys(spec) }
        }
        // Characters as a person types them: the first through the tap's own path, which holds it while the field
        // comes up; the rest as real key events, which reach the field by the system's path.
        on("wheel-type") { [weak self] info in
            guard let self, let text = info["text"], self.overLab() else { return }
            Task { await self.type(text) }
        }
        on("wheel-mouse") { [weak self] info in
            guard let self, let kind = info["kind"], let at = info["at"], self.overLab() else { return }
            Task { await self.mouse(kind, at: at) }
        }
        on("wheel-state") { [weak self] _ in
            guard let self else { return }
            Self.record(self.wheelState(), to: "actions.jsonl")
        }
        // Whether a key posted by a process reaches the wheel's tap, which no trigger above depends on.
        on("wheel-tap-probe") { [weak self] _ in
            guard let self, Self.labIsInFront(), let keys = self.wheel.keys, keys.isLive else { return }
            let before = keys.handledCount
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 124, keyDown: down) else { continue }
                event.flags = []
                event.post(tap: .cghidEventTap)
            }
            Task {
                try? await Task.sleep(for: .milliseconds(200))
                Self.record(["wheel": "tap-probe", "seen": keys.handledCount > before ? "yes" : "no"], to: "actions.jsonl")
            }
        }
        // The wheel's actions for the next openings, from a file: `places` keeps those starters (all when absent) and
        // `add` puts more at theirs; `typing` false treats the lab as an app where the centre can't type. The saved
        // actions are never read or touched.
        on("wheel-library") { [weak self] info in
            guard let self, let path = info["path"] else { return }
            guard let library = Self.library(at: URL(fileURLWithPath: path)) else {
                Self.record(["library": "unreadable"], to: "actions.jsonl"); return
            }
            self.wheel.library = { library.actions }
            self.wheel.typingOff = !library.typing
            self.actions.typedRunsWith = library.actions.typed.kind == .agent ? library.actions.typed : nil
            Self.record(["library": "set", "count": "\(library.actions.actions.count)"], to: "actions.jsonl")
        }
    }

    private func key(_ name: String, phase: String) async {
        let downs = phase == "up" ? [false] : phase == "down" ? [true] : [true, false]
        for (index, down) in downs.enumerated() {
            if index > 0 { try? await Task.sleep(for: .milliseconds(30)) }
            _ = send(name, down: down)
        }
    }

    private func keys(_ spec: String) async {
        for step in spec.split(separator: ",").map(String.init) {
            if let wait = Int(step) {
                try? await Task.sleep(for: .milliseconds(wait))
            } else if step == "open" {
                wheel.shortcut()
            } else {
                for token in step.split(separator: "+").map(String.init) {
                    _ = token.hasSuffix("-") ? send(String(token.dropLast()), down: false) : send(token, down: true)
                }
            }
        }
    }

    /// A lab is in front, or the wheel's own field has the keys over it: the field's window is then the focused one.
    private func overLab() -> Bool { wheel.field.shown || Self.labIsInFront() }

    private func type(_ text: String) async {
        for (index, character) in text.enumerated() {
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down) else { continue }
                event.flags = []
                let units = Array(String(character).utf16)
                event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                if index == 0 {
                    let taken = wheel.keys?.handle(down ? .keyDown : .keyUp, event) ?? false
                    if down { Self.record(["wheel": "key", "key": String(character), "down": "yes", "taken": taken ? "yes" : "no"], to: "actions.jsonl") }
                } else {
                    event.post(tap: .cghidEventTap)
                }
                try? await Task.sleep(for: .milliseconds(25))
            }
        }
    }

    /// One key event through the wheel's tap, logged; true when it stopped there.
    private func send(_ name: String, down: Bool) -> Bool {
        var codes: [String: CGKeyCode] = ["up": 126, "right": 124, "down": 125, "left": 123, "escape": 53, "return": 36,
                                          "delete": 51, "space": 49, "tab": 48, "f5": 96]
        // `code:33`: that key as the current layout types it, a dead key included.
        if name.hasPrefix("code:"), let code = CGKeyCode(name.dropFirst(5)) { codes[name] = code }
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: codes[name] ?? 0, keyDown: down) else { return false }
        // A new event takes the modifiers held right now; these stand for a bare key.
        event.flags = []
        if codes[name] == nil {
            let units = Array(name.utf16)
            event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        }
        // The field has the keys: they go to it the way a person's do.
        if wheel.keys?.mode == .typing {
            event.post(tap: .cghidEventTap)
            Self.record(["wheel": "key", "key": name, "down": down ? "yes" : "no", "taken": "field"], to: "actions.jsonl")
            return false
        }
        let taken = wheel.keys?.handle(down ? .keyDown : .keyUp, event) ?? false
        Self.record(["wheel": "key", "key": name, "down": down ? "yes" : "no", "taken": taken ? "yes" : "no"], to: "actions.jsonl")
        return taken
    }

    private func mouse(_ kind: String, at: String) async {
        guard let keys = wheel.keys, let point = canvasPoint(at) else {
            Self.record(["wheel": "mouse", "at": at, "found": "no"], to: "actions.jsonl"); return
        }
        let origin = wheel.panel.axOrigin, screen = CGPoint(x: origin.x + point.x, y: origin.y + point.y)
        func post(_ type: CGEventType) -> Bool {
            guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: screen, mouseButton: .left) else { return false }
            event.flags = []
            return keys.handle(type, event)
        }
        guard kind == "click" else { _ = post(.mouseMoved); return }
        let taken = post(.leftMouseDown)
        try? await Task.sleep(for: .milliseconds(40))
        _ = post(.leftMouseUp)
        Self.record(["wheel": "mouse", "at": at, "taken": taken ? "yes" : "no"], to: "actions.jsonl")
    }

    /// A petal's or the centre's middle on the canvas, or a corner no piece reaches.
    private func canvasPoint(_ at: String) -> CGPoint? {
        let motion = wheel.motion, pieces = motion.pieces()
        if at == "outside" { return CGPoint(x: 12, y: 12) }
        if at == "centre" { return pieces.first { $0.id == "centre" }?.centre }
        let ring = motion.choice.contains { !$0.leaving } ? motion.choice : motion.root
        guard let node = ring.first(where: { !$0.leaving && $0.petal.place.rawValue == at }) else { return nil }
        return pieces.first { $0.id == node.id }?.centre
    }

    private func wheelState() -> [String: String] {
        let model = wheel.wheel, ink = wheel.frame.ink, frame = wheel.panel.window.frame
        var entry: [String: String] = [
            "wheel": "state",
            "open": model.isOpen ? "yes" : "no",
            "pointed": model.gesture.pointed?.rawValue ?? "",
            "named": model.named ? "yes" : "no",
            "bloomed": model.bloomed ? "yes" : "no",
            "ink": ink.plain ? "plain" : ink.dark ? "dark" : "light",
            "hub": "\(Int(wheel.hub.x)),\(Int(wheel.hub.y))",
            "panel": "\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width)),\(Int(frame.height))",
            "shown": wheel.shown ? "yes" : "no",
            "tapLive": wheel.keys?.isLive == true ? "yes" : "no",
            "holder": drop.holder?.name ?? "",
        ]
        entry["level"] = switch model.level {
        case .closed: "closed"
        case .root: "root"
        case let .choices(action): "choices:" + action.name
        case .typing(from: .root): "typing"
        case let .typing(from: .choices(action)): "typing:" + action.name
        }
        entry["typing"] = model.canType ? "yes" : "no"
        entry["fieldKey"] = wheel.field.shown && wheel.field.panel.window.isKeyWindow ? "yes" : "no"
        entry["fieldText"] = wheel.field.model.text
        entry["frontmost"] = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        for node in wheel.motion.root where !node.leaving { entry["title." + node.petal.place.rawValue] = node.petal.title }
        return entry
    }

    private static func library(at url: URL) -> (actions: ActionLibrary, typing: Bool)? {
        struct Added: Decodable { var name: String, symbol: String, place: ActionPlace, values: [ActionPlace: String]? }
        // `agent`: the starters at these places run as agents, and `typedAgent` a typed instruction; `typing` false: the
        // centre can't type.
        struct Spec: Decodable { var places: [ActionPlace]?, add: [Added]?, agent: [ActionPlace]?, typedAgent: Bool?, typing: Bool? }
        guard let data = try? Data(contentsOf: url), let spec = try? JSONDecoder().decode(Spec.self, from: data) else { return nil }
        let kept = ActionLibrary.starters.actions.filter { spec.places?.contains($0.place) ?? true }.map { action in
            var action = action
            if spec.agent?.contains(action.place) == true { action.runsWith.kind = .agent }
            return action
        }
        let added = (spec.add ?? []).map { added in
            let choice = added.values.map { ActionChoice(name: added.name, values: $0) }
            return Action(symbol: added.symbol, name: added.name, instruction: added.name + (choice == nil ? "." : ": " + Action.choiceMark + "."),
                          choice: choice, place: added.place)
        }
        var library = ActionLibrary(actions: kept + added)
        if spec.typedAgent == true { library.typed.kind = .agent }
        return (library, spec.typing ?? true)
    }
}
#endif
