import AppKit

/// Where the editor sits in the window: a chat's bottom composer, a reply in a thread pane, a side
/// panel, a sheet, a box inside nested scroll views, or the whole window as a document.
@MainActor enum Layouts {
    static func label(_ text: String, bold: Bool = false) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        if bold { field.font = .boldSystemFont(ofSize: 13) }
        return field
    }

    static func messages(_ rtl: Bool) -> [NSView] {
        let lines = rtl ? ["سارة: صباح الخير! هل تم النشر الليلة الماضية؟", "كريم: نعم، لكن صفحة الدخول بدت غريبة."]
            : ["Sam: Morning! Did the deploy go out last night?", "Priya: It did, but the login page looked off.", "Sam: Can you send the release notes?"]
        return lines.map { label($0) }
    }

    static func stack(_ views: [NSView], _ orientation: NSUserInterfaceLayoutOrientation = .vertical, spacing: CGFloat = 10) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = orientation; stack.spacing = spacing
        stack.alignment = orientation == .vertical ? .leading : .top
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    /// A bordered box holding the editor at a fixed height, like a composer.
    static func composer(_ editor: Editor, height: CGFloat = 90) -> NSView {
        let box = NSBox()
        box.boxType = .custom; box.cornerRadius = 10; box.borderColor = .separatorColor; box.borderWidth = 1
        box.contentViewMargins = NSSize(width: 6, height: 4)
        editor.view.translatesAutoresizingMaskIntoConstraints = false
        box.contentView?.addSubview(editor.view)
        if let content = box.contentView {
            NSLayoutConstraint.activate([
                editor.view.leadingAnchor.constraint(equalTo: content.leadingAnchor), editor.view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                editor.view.topAnchor.constraint(equalTo: content.topAnchor), editor.view.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            ])
        }
        box.translatesAutoresizingMaskIntoConstraints = false
        box.heightAnchor.constraint(equalToConstant: height).isActive = true
        return box
    }

    static func pin(_ view: NSView, in container: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor), view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor), view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    /// A column: header and messages at the top, the composer at the bottom, filling its width.
    static func column(_ title: String, _ editor: Editor?, rtl: Bool) -> NSView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .vertical)
        var views: [NSView] = [label(title, bold: true), spacer] + messages(rtl)
        if let editor { views.append(composer(editor)) }
        let column = stack(views)
        for view in views where view !== views[0] { view.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -28).isActive = true }
        return column
    }

    static func build(_ spec: Case, editor: Editor, in window: NSWindow) {
        let root = NSView()
        window.contentView = root
        switch spec.layout {
        case "thread", "side-panel":
            let side = spec.layout == "thread" ? column("Thread", editor, rtl: spec.rtl) : column("Assistant", editor, rtl: spec.rtl)
            let main = spec.layout == "thread" ? column("# release", nil, rtl: spec.rtl)
                : stack([label("Quarterly planning", bold: true)] + (0..<6).map { _ in label("The roadmap for the next two sprints is final. Priorities are clear.") })
            let split = stack([main, side], .horizontal, spacing: 0)
            split.edgeInsets = NSEdgeInsetsZero; split.alignment = .top
            for view in [main, side] { view.heightAnchor.constraint(equalTo: split.heightAnchor).isActive = true }
            side.widthAnchor.constraint(equalToConstant: spec.layout == "thread" ? 360 : 320).isActive = true
            pin(split, in: root)
        case "modal":
            pin(stack([label("Feed", bold: true), label("Recent posts from your team.")]), in: root)
            let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 260), styleMask: [.titled], backing: .buffered, defer: false)
            sheet.title = "oops native lab · bakeoff · \(spec.id) · New post"
            let content = stack([label("New post", bold: true), composer(editor, height: 160)])
            if let box = content.views.last { box.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -28).isActive = true }
            sheet.contentView = NSView()
            pin(content, in: sheet.contentView!)
            window.beginSheet(sheet)
        case "nested-scroll":
            let filler = { (count: Int) in (0..<count).map { label("Earlier note \($0 + 1): the build moved to the new runners and the cache is warm again.") } }
            let inner = NSScrollView(), outer = NSScrollView()
            let innerStack = stack(filler(8) + [composer(editor, height: 70)] + filler(4))
            inner.documentView = innerStack; inner.hasVerticalScroller = true
            innerStack.widthAnchor.constraint(equalTo: inner.contentView.widthAnchor).isActive = true
            inner.translatesAutoresizingMaskIntoConstraints = false
            inner.heightAnchor.constraint(equalToConstant: 300).isActive = true
            let outerStack = stack(filler(10) + [inner] + filler(10))
            outer.documentView = outerStack; outer.hasVerticalScroller = true
            outerStack.widthAnchor.constraint(equalTo: outer.contentView.widthAnchor).isActive = true
            for view in outerStack.views + innerStack.views { view.widthAnchor.constraint(equalTo: view.superview!.widthAnchor, constant: -28).isActive = true }
            pin(outer, in: root)
            root.layoutSubtreeIfNeeded()
            inner.contentView.scroll(to: NSPoint(x: 0, y: max(0, innerStack.views[8].frame.minY - 60)))
            outer.contentView.scroll(to: NSPoint(x: 0, y: max(0, inner.frame.minY - 120)))
        case "document":
            let page = stack([label("Weekly update", bold: true)])
            editor.view.translatesAutoresizingMaskIntoConstraints = false
            page.addArrangedSubview(editor.view)
            editor.view.widthAnchor.constraint(equalTo: page.widthAnchor, constant: -28).isActive = true
            editor.view.heightAnchor.constraint(greaterThanOrEqualToConstant: 500).isActive = true
            pin(page, in: root)
        default:
            pin(column("# release", editor, rtl: spec.rtl), in: root)
        }
    }

    /// The window the editor is in: the sheet when there is one.
    static func editorWindow(_ window: NSWindow) -> NSWindow { window.attachedSheet ?? window }
}
