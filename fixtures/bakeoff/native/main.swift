import AppKit

// The bake-off's native shell: AppKit (TextKit 1 and 2, NSTextField), SwiftUI and a custom view that
// draws its own text, in the layouts apps use. Usage: NativeShell <server url>. Like the web page, it
// polls <server>/control for the case meant for host "native" and posts the editor's own text (its
// model, not what Accessibility reads) to <server>/state. Windows are titled "oops native lab · …" so
// Oops's lab trigger acts on them. NativeEditors.swift builds the editors, NativeLayouts.swift the
// layouts.

struct Segment { var text = "", mention: String?, emoji: String?
    var label: String { mention.map { "@" + $0 } ?? emoji ?? text }
}

struct Case {
    let id: String, toolkit: String, layout: String, content: String, reaction: String, presentation: String
    let paragraphs: [[Segment]]
    let selection: (Int, Int)
    var rtl: Bool { presentation == "rtl" }
    var fontSize: CGFloat { presentation == "zoom" ? 30 : 15 }
    var text: String { paragraphs.map { $0.map(\.label).joined() }.joined(separator: "\n") }

    init?(_ json: [String: Any]) {
        guard let id = json["id"] as? String, let toolkit = json["toolkit"] as? String,
              let draft = json["draft"] as? [String: Any], let paragraphs = draft["paragraphs"] as? [[[String: String]]] else { return nil }
        self.id = id; self.toolkit = toolkit
        layout = json["layout"] as? String ?? "composer"; content = json["content"] as? String ?? "plain"
        reaction = json["reaction"] as? String ?? "none"; presentation = json["presentation"] as? String ?? "normal"
        self.paragraphs = paragraphs.map { $0.map { Segment(text: $0["text"] ?? "", mention: $0["mention"], emoji: $0["emoji"]) } }
        if let range = json["selection"] as? [Int], range.count == 2 { selection = (range[0], range[1]) }
        else { let caret = json["caret"] as? Int ?? 0; selection = (caret, caret) }
    }
}

/// What every editor gives the shell: its view, its text by the shared rules (a mention as "@Name",
/// an emoji image as its emoji, paragraphs joined by "\n"), and the edits behaviours need.
@MainActor protocol Editor: AnyObject {
    var view: NSView { get }
    var onChange: (() -> Void)? { get set }
    func text() -> String
    func counts() -> [String: Int]
    func focus()
    func select(_ start: Int, _ end: Int)
    func caret() -> Int?
    func insert(_ string: String)
    func rerender()
}

@MainActor final class Shell: NSObject, NSApplicationDelegate {
    let server: URL
    var window: NSWindow!
    var nonce: String?, editor: Editor?, error: String?, ready = false, reported = ""
    let behaviours = Behaviours()
    init(server: URL) { self.server = server }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = Self.menu()
        window = NSWindow(contentRect: NSRect(x: 185, y: 0, width: 1100, height: 760),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.setFrameTopLeftPoint(NSPoint(x: 185, y: (NSScreen.screens.first?.frame.maxY ?? 956) - 95))
        window.title = "oops native lab · bakeoff"
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    /// The Edit menu gives ⌘C, ⌘V and ⌘A their actions, as in any app.
    static func menu() -> NSMenu {
        let main = NSMenu(), app = NSMenuItem(), edit = NSMenuItem()
        main.addItem(app); main.addItem(edit)
        app.submenu = NSMenu(); app.submenu?.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let menu = NSMenu(title: "Edit")
        for (title, action, key) in [("Undo", "undo:", "z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            menu.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        edit.submenu = menu
        return main
    }

    private var polling = false
    private func poll() {
        guard !polling else { return }
        polling = true
        URLSession.shared.dataTask(with: server.appendingPathComponent("control")) { data, _, _ in
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.polling = false
                    if let json, json["host"] as? String == "native", let next = json["nonce"] as? String, next != self.nonce,
                       let body = json["case"] as? [String: Any] {
                        self.nonce = next
                        self.show(body)
                    }
                    self.report()
                }
            }
        }.resume()
    }

    private func show(_ body: [String: Any]) {
        behaviours.reset()
        window.endSheet(window.attachedSheet ?? NSWindow())
        editor = nil; ready = false; error = nil
        guard let spec = Case(body) else { error = "bad case"; return }
        guard let made = Editors.make(spec) else { error = "unknown toolkit \(spec.toolkit)"; return }
        editor = made
        window.title = "oops native lab · bakeoff · \(spec.id)"
        Layouts.build(spec, editor: made, in: window)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in
            guard editor === made else { return }
            made.focus()
            made.select(spec.selection.0, spec.selection.1)
            behaviours.apply(spec, made, window: Layouts.editorWindow(window))
            ready = true
        }
    }

    private func report() {
        var state: [String: Any] = ["host": "native", "nonce": nonce ?? NSNull(), "ready": ready, "error": error ?? NSNull(),
                                    "composing": behaviours.composing()]
        if let editor { state["text"] = editor.text(); state["counts"] = editor.counts() }
        guard let data = try? JSONSerialization.data(withJSONObject: state, options: .sortedKeys),
              let string = String(data: data, encoding: .utf8), string != reported else { return }
        reported = string
        var request = URLRequest(url: server.appendingPathComponent("state"))
        request.httpMethod = "POST"; request.httpBody = data
        URLSession.shared.dataTask(with: request).resume()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

guard CommandLine.arguments.count > 1, let server = URL(string: CommandLine.arguments[1]) else {
    FileHandle.standardError.write(Data("usage: NativeShell <server url>\n".utf8)); exit(2)
}
let app = NSApplication.shared
let shell = MainActor.assumeIsolated { Shell(server: server) }
app.delegate = shell
app.setActivationPolicy(.regular)
app.run()
