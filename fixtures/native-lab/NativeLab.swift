import AppKit
import SwiftUI
import WebKit

// Native lab: editors oops meets outside Chromium, in a separate process like a real target app.
// WebKit runs the composer-lab page (Mail's engine); AppKit and SwiftUI cover native fields.
// Usage: NativeLab <control.json> <composer-lab/index.html>; switches to whatever control.json names.
// End-to-end runs (fixtures/e2e) use `e2e` (a plain text view with the control's `text` and optional
// `selection` "location,length", and a `variant`: `ime` leaves a composition at the caret, `readonly` can't be
// edited, `remount` rebuilds the text view after each edit like a remounted component, and every U+FFFC in
// the text becomes an attachment chip), `e2e-secure` (a password field), `e2e-opaque` (a text view that hides
// its text from Accessibility, like editors only copy and paste can reach), `append` to type into the
// current editor mid-correction, and `other` to focus a second editor below it, holding that text. The
// focused editor's text is mirrored to <control.json>.state. `web-*` scenarios with a `url` show that page in
// the WebKit view instead (fixtures/e2e/web.html), which reports its own text.

let draft = "hey, i just pushed the fix for the login bug. it shoud work now but can you double check befor we ship it ?"
let document = """
Hi team,

Quick update on the quarterly planing. We have finalised the roadmap for the next two sprints and the priorites are now clear.

The design review is moved to thursday, please make sure your slides are ready by wedensday evening.

Thanks,
M
"""

final class Lab: NSObject, NSApplicationDelegate, NSTextViewDelegate {
    let control: URL, page: URL
    var window: NSWindow!
    let web = WKWebView(frame: .zero)
    var nonce = ""
    var current: NSTextView?
    var reported: String?
    var served: URL?
    init(control: URL, page: URL) { self.control = control; self.page = page }

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 185, y: 0, width: 1100, height: 760),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        let top = (NSScreen.screens.first?.frame.maxY ?? 956) - 95
        window.setFrameTopLeftPoint(NSPoint(x: 185, y: top))
        web.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        show("appkit-document")
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.poll() }
    }

    private func poll() {
        defer { report() }
        guard let data = try? Data(contentsOf: control),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let scenario = object["scenario"], let next = object["nonce"], next != nonce else { return }
        nonce = next
        // Served pages (fixtures/e2e/web.html) for another browser are left alone; this lab's own one has a `url`.
        if scenario.hasPrefix("web-") {
            guard let url = object["url"].flatMap(URL.init(string:)) else { return }
            if served != url { served = url; web.load(URLRequest(url: url)) }
            current = nil
            window.title = "oops native lab · web"
            window.contentView = web
            window.makeFirstResponder(web)
            return
        }
        if let append = object["append"], let current {
            current.insertText(append, replacementRange: NSRange(location: (current.string as NSString).length, length: 0)); return
        }
        if let other = object["other"], let current { return otherField(other, below: current) }
        current = nil; remount = false
        switch scenario {
        case "e2e":
            let parts = (object["selection"] ?? "").split(separator: ",").compactMap { Int($0) }
            let caret: Caret = parts.count == 2 ? .selection(NSRange(location: parts[0], length: parts[1])) : .end
            window.title = "oops native lab · e2e"
            text(object["text"] ?? "", caret: caret)
            variant(object["variant"])
        case "e2e-opaque":
            let parts = (object["selection"] ?? "").split(separator: ",").compactMap { Int($0) }
            window.title = "oops native lab · e2e-opaque"
            let scroll = NSScrollView(frame: NSRect(origin: .zero, size: window.contentRect(forFrameRect: window.frame).size))
            // Hidden from Accessibility: focus reports the scroll view, a group with no text.
            let text = NSTextView(frame: scroll.bounds)
            text.setAccessibilityElement(false); scroll.setAccessibilityRole(.group)
            text.string = object["text"] ?? ""; text.font = .systemFont(ofSize: 15); text.autoresizingMask = [.width]
            scroll.documentView = text; scroll.hasVerticalScroller = true
            window.contentView = scroll; window.makeFirstResponder(text)
            if parts.count == 2 { text.setSelectedRange(NSRange(location: parts[0], length: parts[1])) }
            current = text
        case "e2e-secure":
            window.title = "oops native lab · e2e-secure"
            let root = NSView(frame: NSRect(origin: .zero, size: window.contentRect(forFrameRect: window.frame).size))
            let field = NSSecureTextField(frame: NSRect(x: 24, y: 700, width: 400, height: 28))
            field.stringValue = object["text"] ?? "hunter2 pasword"; field.autoresizingMask = [.minYMargin]
            root.addSubview(field); window.contentView = root; window.makeFirstResponder(field)
        default: show(scenario)
        }
    }

    private func variant(_ name: String?) {
        guard let text = current else { return }
        switch name {
        case "ime":
            text.setMarkedText("にほんご", selectedRange: NSRange(location: 4, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        case "readonly": text.isEditable = false
        case "remount": remount = true
        default: break
        }
        // Each U+FFFC is a chip, as mentions and emoji images are in native composers.
        let string = text.string as NSString
        for index in (0..<string.length).reversed() where string.character(at: index) == 0xFFFC {
            let chip = NSTextAttachment()
            chip.image = NSImage(systemSymbolName: "person.crop.circle", accessibilityDescription: nil)
            text.textStorage?.replaceCharacters(in: NSRange(location: index, length: 1), with: NSAttributedString(attachment: chip))
        }
    }

    /// A remounted editor: 60 ms after each edit, a new text view with the same text and selection replaces it.
    var remount = false
    func textDidChange(_ notification: Notification) {
        guard remount, let old = notification.object as? NSTextView, old === current else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            guard let self, old === self.current, let storage = old.textStorage else { return }
            let selection = old.selectedRange()
            self.text("", caret: .end)
            self.current?.textStorage?.setAttributedString(storage)
            self.current?.setSelectedRange(selection)
        }
    }

    /// The editor's text and the nonce it belongs to, written only when they change.
    private func report() {
        let state = "\(nonce)\u{0}\(current?.string ?? "")"
        guard state != reported else { return }
        reported = state
        let object: [String: Any] = ["nonce": nonce, "text": current?.string ?? NSNull()]
        if let data = try? JSONSerialization.data(withJSONObject: object) {
            try? data.write(to: control.appendingPathExtension("state"), options: .atomic)
        }
    }

    private func show(_ scenario: String) {
        window.title = "oops native lab · \(scenario)"
        if scenario.hasPrefix("webkit-") {
            let hash = String(scenario.dropFirst("webkit-".count))
            window.contentView = web
            web.evaluateJavaScript("location.hash = '\(hash)'")
            window.makeFirstResponder(web)
            return
        }
        switch scenario {
        case "appkit-document": text(document, caret: .end)
        case "appkit-middle": text(document, caret: .at(140))
        case "appkit-selection": text(document, caret: .selection(NSRange(location: 52, length: 24)))
        case "appkit-scrolled": text(String(repeating: document + "\n", count: 12), caret: .end, scrollToTop: true)
        case "appkit-rtl": text("مرحبا بالفريق، تم تحديث خطة الربع القادم وأولويات العمل أصبحت واضحة الآن.\nشكرا لكم", caret: .end)
        case "appkit-large": text(document, caret: .end, font: .systemFont(ofSize: 40))
        case "appkit-chat": chat()
        case "appkit-field": field(search: false)
        case "appkit-search": field(search: true)
        case "swiftui-editor": host(AnyView(EditorScenario()))
        case "swiftui-field": host(AnyView(FieldScenario()))
        default: text("Unknown scenario \(scenario)", caret: .end)
        }
    }

    enum Caret { case end, at(Int), selection(NSRange) }

    private func makeText(_ string: String, font: NSFont) -> (NSScrollView, NSTextView) {
        let scroll = NSTextView.scrollableTextView()
        let text = scroll.documentView as! NSTextView
        text.font = font; text.string = string; text.textContainerInset = NSSize(width: 24, height: 20)
        text.isAutomaticSpellingCorrectionEnabled = false; text.isContinuousSpellCheckingEnabled = false
        return (scroll, text)
    }
    private func select(_ text: NSTextView, _ caret: Caret) {
        let length = (text.string as NSString).length
        let range: NSRange = switch caret {
        case .end: NSRange(location: length, length: 0)
        case .at(let index): NSRange(location: min(index, length), length: 0)
        case .selection(let selection): selection
        }
        text.setSelectedRange(range)
    }

    private func text(_ string: String, caret: Caret, font: NSFont = .systemFont(ofSize: 15), scrollToTop: Bool = false) {
        let (scroll, text) = makeText(string, font: font)
        window.contentView = scroll
        window.makeFirstResponder(text)
        select(text, caret)
        current = text
        text.delegate = self
        if scrollToTop { text.scroll(.zero) } else { text.scrollRangeToVisible(text.selectedRange()) }
    }

    /// A second text view under the current one, in the same window, holding `string` and focused; the first
    /// stays alive as it was, so the two are different editors.
    private func otherField(_ string: String, below first: NSTextView) {
        guard let upper = first.enclosingScrollView else { return }
        let size = window.contentRect(forFrameRect: window.frame).size
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        window.contentView = root
        upper.frame = NSRect(x: 0, y: size.height / 2, width: size.width, height: size.height / 2)
        upper.autoresizingMask = [.width, .height, .minYMargin]
        let (lower, text) = makeText(string, font: .systemFont(ofSize: 15))
        lower.frame = NSRect(x: 0, y: 0, width: size.width, height: size.height / 2)
        lower.autoresizingMask = [.width, .height, .maxYMargin]
        root.addSubview(upper); root.addSubview(lower)
        window.makeFirstResponder(text)
        select(text, .end)
        current = text
        text.delegate = self
    }

    /// History above, a bordered two-line composer at the bottom, like a native chat app.
    private func chat() {
        // Sized before adding controls, so autoresizing keeps them where they are placed.
        let root = NSView(frame: NSRect(origin: .zero, size: window.contentRect(forFrameRect: window.frame).size))
        let history = NSTextField(labelWithString: "Can you send the release notes before the stand-up?")
        history.frame = NSRect(x: 24, y: 640, width: 600, height: 20); history.autoresizingMask = [.minYMargin]
        let box = NSBox(); box.boxType = .custom; box.cornerRadius = 12; box.borderColor = .separatorColor; box.borderWidth = 1
        box.fillColor = .textBackgroundColor
        box.frame = NSRect(x: 16, y: 16, width: 1068, height: 74); box.autoresizingMask = [.width, .maxYMargin]
        let (scroll, text) = makeText(draft, font: .systemFont(ofSize: 15))
        scroll.frame = box.contentView!.bounds.insetBy(dx: 4, dy: 4); scroll.autoresizingMask = [.width, .height]
        scroll.drawsBackground = false; text.drawsBackground = false
        box.contentView!.addSubview(scroll)
        root.addSubview(history); root.addSubview(box)
        window.contentView = root
        window.makeFirstResponder(text)
        select(text, .end)
    }

    /// A single-line field (or search field) near the top of the window.
    private func field(search: Bool) {
        // Sized before adding controls, so autoresizing keeps them where they are placed.
        let root = NSView(frame: NSRect(origin: .zero, size: window.contentRect(forFrameRect: window.frame).size))
        let field: NSTextField = search ? NSSearchField() : NSTextField()
        field.stringValue = "recieve aproval for the budjet"
        field.frame = search ? NSRect(x: 780, y: 700, width: 300, height: 28) : NSRect(x: 24, y: 700, width: 1052, height: 28)
        field.autoresizingMask = [.minYMargin]
        root.addSubview(field)
        window.contentView = root
        window.makeFirstResponder(field)
        // Editing happens in the window's field editor, a hidden NSTextView.
        if let editor = field.currentEditor() { editor.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0) }
    }

    private func host(_ view: AnyView) {
        window.contentView = NSHostingView(rootView: view)
    }
}

struct EditorScenario: View {
    @State private var text = document
    @FocusState private var focused: Bool
    var body: some View {
        TextEditor(text: $text).font(.system(size: 15)).focused($focused).padding(20)
            .onAppear { DispatchQueue.main.async { focused = true } }
    }
}

struct FieldScenario: View {
    @State private var text = "the build is green now, ill merge after lunch if nobody objets"
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading) {
            Spacer()
            Text("Ping me when the build is green.").foregroundStyle(.secondary)
            TextField("Message", text: $text).textFieldStyle(.roundedBorder).focused($focused)
        }
        .padding(16)
        .onAppear { DispatchQueue.main.async { focused = true } }
    }
}

let arguments = CommandLine.arguments
let app = NSApplication.shared
app.setActivationPolicy(.regular)
// Text views route Command-V, undo and select-all through the Edit menu, as in any real app.
let mainMenu = NSMenu(), edit = NSMenu(title: "Edit")
mainMenu.addItem(withTitle: "", action: nil, keyEquivalent: "").submenu = NSMenu()
edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
mainMenu.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = edit
app.mainMenu = mainMenu
let lab = Lab(control: URL(fileURLWithPath: arguments[1]), page: URL(fileURLWithPath: arguments[2]))
app.delegate = lab
app.run()
