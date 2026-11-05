import UIKit

struct CatalystCase {
    let toolkit: String, layout: String, content: String, reaction: String, rtl: Bool, fontSize: CGFloat
    let paragraphs: [[Segment]]
    let selection: (Int, Int)

    init(body: [String: Any], toolkit: String, paragraphs: [[Segment]]) {
        self.toolkit = toolkit; self.paragraphs = paragraphs
        layout = body["layout"] as? String ?? "composer"; content = body["content"] as? String ?? "plain"
        reaction = body["reaction"] as? String ?? "none"
        rtl = body["presentation"] as? String == "rtl"; fontSize = body["presentation"] as? String == "zoom" ? 30 : 15
        if let range = body["selection"] as? [Int], range.count == 2 { selection = (range[0], range[1]) }
        else { let caret = body["caret"] as? Int ?? 0; selection = (caret, caret) }
    }

    var text: String { paragraphs.map { $0.map(\.label).joined() }.joined(separator: "\n") }
}

extension SceneDelegate {
    /// UITextView holds mentions and emoji images as attachments; UITextField holds plain text.
    func makeEditor(_ spec: CatalystCase) -> UIView {
        let font = UIFont.systemFont(ofSize: spec.fontSize)
        if spec.toolkit == "catalyst-field" || spec.toolkit == "catalyst-secure" {
            let field = ComposerField()
            field.text = spec.text; field.font = font; field.placeholder = "Message"
            field.isSecureTextEntry = spec.toolkit == "catalyst-secure"
            field.textAlignment = spec.rtl ? .right : .natural
            field.interceptPaste = spec.reaction == "paste-intercept"
            field.addTarget(self, action: #selector(fieldChanged), for: .editingChanged)
            field.accessibilityLabel = "Message"
            self.field = field
            return field
        }
        let view = ComposerTextView()
        view.font = font; view.backgroundColor = .clear
        view.autocorrectionType = .no; view.spellCheckingType = .no; view.smartQuotesType = .no
        view.attributedText = attributed(spec, font: font)
        view.interceptPaste = spec.reaction == "paste-intercept"
        view.delegate = self
        view.accessibilityLabel = "Message"
        textView = view
        return view
    }

    func attributed(_ spec: CatalystCase, font: UIFont) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        if spec.rtl { style.baseWritingDirection = .rightToLeft; style.alignment = .right }
        let base: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: style, .foregroundColor: UIColor.label]
        let result = NSMutableAttributedString()
        for (index, paragraph) in spec.paragraphs.enumerated() {
            if index > 0 { result.append(NSAttributedString(string: "\n", attributes: base)) }
            for segment in paragraph {
                guard segment.mention != nil || segment.emoji != nil else { result.append(NSAttributedString(string: segment.label, attributes: base)); continue }
                let label = NSAttributedString(string: segment.label, attributes: [.font: font, .foregroundColor: segment.mention != nil ? UIColor.systemBlue : UIColor.label])
                let image = UIGraphicsImageRenderer(size: label.size()).image { _ in label.draw(at: .zero) }
                let attachment = NSTextAttachment(image: image)
                attachment.bounds = CGRect(x: 0, y: font.descender, width: image.size.width, height: image.size.height)
                let piece = NSMutableAttributedString(attachment: attachment)
                piece.addAttributes(base.merging([.bakeoffLabel: segment.label]) { a, _ in a }, range: NSRange(location: 0, length: piece.length))
                result.append(piece)
            }
        }
        return result
    }

    /// Draft offsets (an attachment counts as its label) to storage offsets.
    func storageOffset(_ offset: Int) -> Int {
        guard let string = textView?.attributedText else { return offset }
        var remaining = offset, at = 0
        while at < string.length, remaining > 0 {
            remaining -= (string.attribute(.bakeoffLabel, at: at, effectiveRange: nil) as? String).map { ($0 as NSString).length } ?? 1
            at += 1
        }
        return at
    }

    func select(_ start: Int, _ end: Int) {
        let input: UITextInput? = textView ?? field
        guard let input, let from = input.position(from: input.beginningOfDocument, offset: storageOffset(start)),
              let to = input.position(from: input.beginningOfDocument, offset: storageOffset(end)) else { return }
        input.selectedTextRange = input.textRange(from: from, to: to)
    }

    func caret() -> Int? {
        let input: UITextInput? = textView ?? field
        guard let input, let range = input.selectedTextRange, range.isEmpty else { return nil }
        let offset = input.offset(from: input.beginningOfDocument, to: range.start)
        guard let string = textView?.attributedText else { return offset }
        return (0..<min(offset, string.length)).reduce(0) { sum, at in
            sum + ((string.attribute(.bakeoffLabel, at: at, effectiveRange: nil) as? String).map { ($0 as NSString).length } ?? 1)
        }
    }

    func textViewDidChange(_ view: UITextView) { changed() }
    func textViewDidChangeSelection(_ view: UITextView) { checkMenu() }
    @objc func fieldChanged() { changed() }

    /// A re-render reassigns the text from the app's copy, as model-driven views do.
    func changed() {
        checkMenu()
        guard nonce != nil, !rerendering, reactionIsRerender else { return }
        rerendering = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [self] in
            if let textView {
                let range = textView.selectedRange
                textView.attributedText = NSAttributedString(attributedString: textView.attributedText)
                textView.selectedRange = range
            } else if let field, let range = field.selectedTextRange {
                field.text = field.text
                field.selectedTextRange = range
            }
            DispatchQueue.main.async { self.rerendering = false }
        }
    }

    var reactionIsRerender: Bool { window?.rootViewController?.view.accessibilityHint == "rerender" }

    /// A "/" just typed opened a menu over the composer; it closes when the caret leaves the "/".
    func openMenu() {
        guard let root = window?.rootViewController?.view, let input: UITextInput = textView ?? field,
              let range = input.selectedTextRange else { return }
        menuAnchor = (text() as NSString? ?? "").range(of: "/", options: .backwards).location
        let caret = input.caretRect(for: range.start)
        let list = UIStackView(arrangedSubviews: ["Summarize", "Insert table", "Mention someone", "Add emoji"].map {
            let label = UILabel(); label.text = $0; return label
        })
        list.axis = .vertical; list.spacing = 4
        list.backgroundColor = .secondarySystemBackground; list.layer.cornerRadius = 8
        list.isLayoutMarginsRelativeArrangement = true; list.layoutMargins = UIEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        list.accessibilityLabel = "Commands"
        let origin = (input as? UIView)?.convert(caret.origin, to: root) ?? .zero
        list.frame = CGRect(x: origin.x, y: max(8, origin.y - 130), width: 200, height: 120)
        root.addSubview(list)
        menu = list
    }

    func checkMenu() {
        guard let menu else { return }
        let slash = (text() as NSString? ?? "").range(of: "/", options: .backwards).location
        if slash != menuAnchor || (caret().map { $0 != menuAnchor + 1 } ?? false) { menu.removeFromSuperview(); self.menu = nil }
    }
}
