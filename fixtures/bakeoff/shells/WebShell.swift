import AppKit
import WebKit

// The bake-off's app web view: a WKWebView in a plain AppKit window, the way Tauri apps, Mail's
// composer and other WebKit app shells host an editor. Usage: WebShell <page url>. The window takes
// the page's title. The page can ask for an IME composition ({"ime": text} on the "bakeoff"
// handler): the view starts it through NSTextInputClient, as a Japanese input method would.

final class Shell: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKNavigationDelegate {
    let url: URL
    var window: NSWindow!
    var web: WKWebView!
    var title: NSKeyValueObservation?
    init(url: URL) { self.url = url }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = Self.menu()
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(self, name: "bakeoff")
        web = WKWebView(frame: .zero, configuration: configuration)
        web.navigationDelegate = self
        window = NSWindow(contentRect: NSRect(x: 185, y: 0, width: 1100, height: 760),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.setFrameTopLeftPoint(NSPoint(x: 185, y: (NSScreen.screens.first?.frame.maxY ?? 956) - 95))
        window.contentView = web
        window.title = "oops composer lab · bakeoff"
        title = web.observe(\.title, options: [.new]) { [weak self] web, _ in
            MainActor.assumeIsolated { if let title = web.title, !title.isEmpty { self?.window.title = title } }
        }
        web.load(URLRequest(url: url))
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(web)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The Edit menu gives ⌘C, ⌘V and ⌘A their actions, as in any app; without it ⌘V never pastes.
    static func menu() -> NSMenu {
        let main = NSMenu(), app = NSMenuItem(), edit = NSMenuItem()
        main.addItem(app); main.addItem(edit)
        app.submenu = NSMenu(); app.submenu?.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let menu = NSMenu(title: "Edit")
        for (title, action, key) in [("Undo", "undo:", "z"), ("Redo", "redo:", "Z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"),
                                     ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            menu.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        edit.submenu = menu
        return main
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        window.makeFirstResponder(web)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let text = body["ime"] as? String else { return }
        window.makeFirstResponder(web)
        // WKWebView answers NSTextInputClient: marked text is a real composition in the page.
        let selector = NSSelectorFromString("setMarkedText:selectedRange:replacementRange:")
        guard web.responds(to: selector), let client = web as Any as? NSTextInputClient else { return }
        client.setMarkedText(text, selectedRange: NSRange(location: (text as NSString).length, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

guard CommandLine.arguments.count > 1, let url = URL(string: CommandLine.arguments[1]) else {
    FileHandle.standardError.write(Data("usage: WebShell <page url>\n".utf8)); exit(2)
}
let app = NSApplication.shared
let shell = Shell(url: url)
app.delegate = shell
app.setActivationPolicy(.regular)
app.run()
