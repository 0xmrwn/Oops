import UIKit

// The bake-off's Mac Catalyst shell (Messages, WhatsApp and other iPad apps on the Mac): UITextView
// and UITextField, bridged to Accessibility by UIKit. Usage: CatalystShell <server url>. Like the
// other shells it polls <server>/control for host "catalyst" and posts the editor's own text to
// <server>/state. The window is titled "oops native lab · …" so Oops's lab trigger acts on it.

struct Segment { var text = "", mention: String?, emoji: String?
    var label: String { mention.map { "@" + $0 } ?? emoji ?? text }
}

extension NSAttributedString.Key { static let bakeoffLabel = NSAttributedString.Key("bakeoffLabel") }

/// A text view whose app takes ⌘V over when `interceptPaste` is on: it inserts the plain text itself,
/// a moment later.
final class ComposerTextView: UITextView {
    var interceptPaste = false
    override func paste(_ sender: Any?) {
        guard interceptPaste, let string = UIPasteboard.general.string else { return super.paste(sender) }
        let range = selectedRange
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [self] in
            if let start = position(from: beginningOfDocument, offset: range.location),
               let end = position(from: start, offset: range.length), let span = textRange(from: start, to: end) {
                replace(span, withText: string)
            }
        }
    }
}

final class ComposerField: UITextField {
    var interceptPaste = false
    override func paste(_ sender: Any?) {
        guard interceptPaste, let string = UIPasteboard.general.string, let range = selectedTextRange else { return super.paste(sender) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [self] in replace(range, withText: string) }
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate, UITextViewDelegate {
    var window: UIWindow?
    var server: URL!
    var nonce: String?, reported = "", ready = false, error: String?
    var textView: ComposerTextView?, field: ComposerField?
    var paragraphs: [[Segment]] = []
    var rerendering = false, menu: UIView?, menuAnchor = -1

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        server = URL(string: ProcessInfo.processInfo.arguments.dropFirst().first { $0.hasPrefix("http") } ?? "http://127.0.0.1:8765/")
        scene.sizeRestrictions?.minimumSize = CGSize(width: 1100, height: 760)
        scene.title = "oops native lab · bakeoff"
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        window.rootViewController?.view.backgroundColor = .systemBackground
        window.makeKeyAndVisible()
        self.window = window
        Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in self?.poll() }
    }

    private var polling = false
    private func poll() {
        guard !polling else { return }
        polling = true
        URLSession.shared.dataTask(with: server.appendingPathComponent("control")) { data, _, _ in
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            DispatchQueue.main.async { [self] in
                polling = false
                if let json, json["host"] as? String == "catalyst", let next = json["nonce"] as? String, next != nonce,
                   let body = json["case"] as? [String: Any] {
                    nonce = next
                    show(body)
                }
                report()
            }
        }.resume()
    }

    func text() -> String? {
        if let field { return field.text ?? "" }
        guard let textView else { return nil }
        let string = textView.attributedText ?? NSAttributedString()
        var out = ""
        string.enumerateAttribute(.bakeoffLabel, in: NSRange(location: 0, length: string.length)) { label, range, _ in
            out += (label as? String) ?? (string.string as NSString).substring(with: range)
        }
        return out
    }

    func counts() -> [String: Int] {
        var chips = 0, images = 0
        let string = textView?.attributedText ?? NSAttributedString()
        string.enumerateAttribute(.bakeoffLabel, in: NSRange(location: 0, length: string.length)) { label, _, _ in
            guard let label = label as? String else { return }
            if label.hasPrefix("@") { chips += 1 } else { images += 1 }
        }
        return ["chips": chips, "images": images]
    }

    private func report() {
        var state: [String: Any] = ["host": "catalyst", "nonce": nonce ?? NSNull(), "ready": ready, "error": error ?? NSNull(),
                                    "composing": textView?.markedTextRange != nil || field?.markedTextRange != nil]
        if let text = text() { state["text"] = text; state["counts"] = counts() }
        guard let data = try? JSONSerialization.data(withJSONObject: state, options: .sortedKeys),
              let string = String(data: data, encoding: .utf8), string != reported else { return }
        reported = string
        var request = URLRequest(url: server.appendingPathComponent("state"))
        request.httpMethod = "POST"; request.httpBody = data
        URLSession.shared.dataTask(with: request).resume()
    }

    private func show(_ body: [String: Any]) {
        ready = false; error = nil; textView = nil; field = nil; menu = nil
        window?.rootViewController?.presentedViewController?.dismiss(animated: false)
        guard let id = body["id"] as? String, let toolkit = body["toolkit"] as? String,
              let draft = body["draft"] as? [String: Any], let raw = draft["paragraphs"] as? [[[String: String]]] else { error = "bad case"; return }
        paragraphs = raw.map { $0.map { Segment(text: $0["text"] ?? "", mention: $0["mention"], emoji: $0["emoji"]) } }
        window?.windowScene?.title = "oops native lab · bakeoff · \(id)"
        let spec = CatalystCase(body: body, toolkit: toolkit, paragraphs: paragraphs)
        let editor = makeEditor(spec)
        CatalystLayouts.build(spec, editor: editor, in: window!.rootViewController!)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [self] in
            editor.becomeFirstResponder()
            select(spec.selection.0, spec.selection.1)
            switch spec.reaction {
            case "slash-menu": openMenu()
            case "ime": (textView as UITextInput? ?? field)?.setMarkedText("にほんご", selectedRange: NSRange(location: 4, length: 0))
            default: break
            }
            ready = true
        }
    }
}
