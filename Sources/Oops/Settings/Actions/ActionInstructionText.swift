import AppKit
import OopsCore
import SwiftUI

/// The text view in its scroll view; the action's instruction holds the pill as U+FFFC.
struct InstructionText: NSViewRepresentable {
    let library: ActionLibraryModel
    let navigation: ActionsNavigation
    let id: UUID
    let controller: InstructionController
    let style: SettingsStyle
    /// The choice's name, which is what the pill says.
    let label: String
    /// The skills the instruction may name, empty while it may not.
    let skills: [String]
    @Binding var height: CGFloat
    @Binding var hidden: Hidden

    var action: Action? { library.action(id) }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        let text = InstructionTextView(usingTextLayoutManager: true)
        text.drawsBackground = false
        text.isRichText = true
        text.importsGraphics = false
        text.allowsUndo = true
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.lineFragmentPadding = 0
        text.textContainerInset = InstructionEditor.inset
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false
        // The system's Writing Tools button floated at the pane's edge.
        text.writingToolsBehavior = .none
        text.insertionPointColor = .textColor
        text.typingAttributes = Coordinator.base
        text.setAccessibilityLabel("Instruction")
        text.delegate = context.coordinator
        text.textLayoutManager?.delegate = context.coordinator.tokenLayout
        context.coordinator.skills = skills
        text.placePill = { [weak coordinator = context.coordinator] in coordinator?.laidOut() }
        scroll.documentView = text
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.scrolled),
                                               name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        context.coordinator.scroll = scroll
        context.coordinator.text = text
        controller.coordinator = context.coordinator
        context.coordinator.load(action?.instruction ?? "")
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        controller.coordinator = coordinator
        let instruction = action?.instruction ?? ""
        if coordinator.text?.string != instruction { coordinator.load(instruction) }
        if coordinator.skills != skills {
            coordinator.skills = skills
            coordinator.markSkills()
        }
        if coordinator.label != label {
            coordinator.label = label
            coordinator.relayoutPill()
        }
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) { coordinator.suggestions.hide() }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: InstructionText
        var skills: [String] = []
        let suggestions = SkillSuggestions()
        /// Held here: the layout manager's delegate is weak.
        let tokenLayout = SkillTokenLayout()
        weak var scroll: NSScrollView?
        weak var text: InstructionTextView?
        var pill: NSView?
        var label: String
        private var loading = false
        /// The panel is being opened, and its own scroll must not close it.
        private var opening = false
        private var offset: CGFloat = 0
        private var measuredWidth: CGFloat = 0
        /// The choice a deleted pill took with it, for undo to bring back.
        private var memory = ActionChoiceMemory()
        /// Where the caret was while the person edited, and when they stopped: a button pressed just after still
        /// inserts there.
        private var caret: Int?
        private var ended: Date?
        private lazy var attachment = ChoiceAttachment(label: label)

        nonisolated static var paragraph: NSParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.minimumLineHeight = PillMetrics.line
            style.maximumLineHeight = PillMetrics.line
            return style
        }

        nonisolated(unsafe) static let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.textColor, .paragraphStyle: paragraph,
        ]

        init(_ parent: InstructionText) {
            self.parent = parent
            label = parent.action?.choice?.name ?? ""
        }

        private func piece(_ string: String) -> NSMutableAttributedString {
            let piece = NSMutableAttributedString(string: string, attributes: Self.base)
            let mark = (string as NSString).range(of: Action.choiceMark)
            if mark.location != NSNotFound { piece.addAttribute(.attachment, value: attachment, range: mark) }
            return piece
        }

        func load(_ instruction: String) {
            guard let text, let storage = text.textStorage else { return }
            loading = true
            storage.setAttributedString(piece(instruction))
            text.typingAttributes = Self.base
            SkillTokens.apply(to: storage, names: skills)
            loading = false
            measure()
        }

        /// Draws the skills the instruction names as tokens, or draws none once it may not name any.
        func markSkills() {
            guard let text, let storage = text.textStorage else { return }
            loading = true
            SkillTokens.apply(to: storage, names: skills)
            loading = false
            suggestions.update(in: text, names: skills)
        }

        func textDidChange(_ notification: Notification) {
            guard !loading, let text else { return }
            normalize()
            text.typingAttributes = Self.base
            if let storage = text.textStorage { SkillTokens.apply(to: storage, names: skills) }
            // An edit can leave the caret where it was, so the list is read again.
            suggestions.update(in: text, names: skills)
            let string = text.string
            // Text and choice in one update, so the action never holds a mark without its choice or a choice without
            // its mark.
            parent.library.update(parent.id) { memory.apply(instruction: string, to: &$0) }
            measure()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let text, text.window?.firstResponder === text else { return }
            caret = text.selectedRange().location
            // Typing next to a token would carry its look into the new letters.
            text.typingAttributes = Self.base
            suggestions.update(in: text, names: skills)
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool { suggestions.handle(selector) }

        func textDidEndEditing(_ notification: Notification) {
            ended = .now
            suggestions.hide()
        }

        /// One pill at most, and every U+FFFC is the pill (text set through Accessibility arrives without its
        /// attachment); a second one pasted in is dropped.
        private func normalize() {
            guard let storage = text?.textStorage else { return }
            let string = storage.string as NSString
            var found = false
            var extra: [NSRange] = []
            var search = NSRange(location: 0, length: string.length)
            while true {
                let range = string.range(of: Action.choiceMark, range: search)
                if range.location == NSNotFound { break }
                if found { extra.append(range) } else {
                    found = true
                    if storage.attribute(.attachment, at: range.location, effectiveRange: nil) as? ChoiceAttachment == nil {
                        loading = true
                        storage.addAttribute(.attachment, value: attachment, range: range)
                        loading = false
                    }
                }
                search = NSRange(location: range.upperBound, length: string.length - range.upperBound)
            }
            guard !extra.isEmpty else { return }
            loading = true
            for range in extra.reversed() { storage.deleteCharacters(in: range) }
            loading = false
        }

        /// Whether text lies past the top or bottom edge of what the editor shows; and a scroll closes the panel,
        /// which points at where the pill was.
        @objc func scrolled() {
            guard let scroll, let text else { return }
            let clip = scroll.contentView.bounds
            if abs(clip.minY - offset) > 0.5 {
                offset = clip.minY
                suggestions.reposition()
                if !opening, parent.navigation.choice != nil { parent.navigation.choice = nil }
            }
            let now = Hidden(above: clip.minY > 1, below: text.frame.height - clip.maxY > 1)
            if now != parent.hidden { DispatchQueue.main.async { self.parent.hidden = now } }
        }

        /// After every layout: the pill follows its place, and a width the text was not measured at (the first layout
        /// comes after the text is loaded) measures it again.
        func laidOut() {
            guard let text else { return }
            if abs(text.frame.width - measuredWidth) > 0.5 { measure() } else {
                placePill()
                scrolled()
            }
        }

        private func measure() {
            guard let text, let layout = text.textLayoutManager else { return }
            measuredWidth = text.frame.width
            layout.ensureLayout(for: layout.documentRange)
            let height = ceil(layout.usageBoundsForTextContainer.height)
            placePill()
            scrolled()
            if abs(height - parent.height) > 0.5 { DispatchQueue.main.async { self.parent.height = height } }
        }

        func relayoutPill() {
            guard let text, let layout = text.textLayoutManager else { return }
            attachment.resize(to: label, in: text)
            layout.invalidateLayout(for: layout.documentRange)
            layout.textViewportLayoutController.layoutViewport()
            text.needsDisplay = true
            measure()
        }

        func insertChoice() {
            guard let text, let storage = text.textStorage else { return }
            let editing = text.window?.firstResponder === text || ended.map { Date.now.timeIntervalSince($0) < 0.5 } == true
            let caret = editing ? min(caret ?? text.selectedRange().location, storage.length) : nil
            memory.forget()
            let insertion = ActionInstruction.insertion(in: storage.string, caret: caret)
            let range = NSRange(location: insertion.location, length: 0)
            guard text.shouldChangeText(in: range, replacementString: insertion.text) else { return }
            storage.replaceCharacters(in: range, with: piece(insertion.text))
            text.didChangeText()
            if editing { text.setSelectedRange(NSRange(location: insertion.location + (insertion.text as NSString).length, length: 0)) }
            DispatchQueue.main.async { self.openChoice(naming: true) }
        }

        /// The pill opens the choice's panel, and closes it when it's open.
        func togglePopover() {
            if parent.navigation.choice != nil { parent.navigation.choice = nil } else { openChoice() }
        }

        /// Opens the choice's panel under the pill. When the pill sits too low for the panel to fit below it, the
        /// instruction scrolls first so the pill's line comes up.
        func openChoice(naming: Bool = false) {
            guard let text, let pill, let window = text.window, let content = window.contentView else { return }
            let mark = (text.string as NSString).range(of: Action.choiceMark)
            guard mark.location != NSNotFound else { return }
            opening = true
            defer { DispatchQueue.main.async { self.opening = false } }
            text.scrollRangeToVisible(mark)
            text.layoutSubtreeIfNeeded()
            func frame() -> CGRect {
                var rect = pill.convert(pill.bounds, to: content)
                if !content.isFlipped { rect.origin.y = content.bounds.height - rect.maxY }
                return rect
            }
            var rect = frame()
            if rect.maxY + ChoicePanel.arrow + ChoicePopover.size.height + 12 > content.bounds.height, let clip = scroll?.contentView {
                // Put the pill's line at the top of what the instruction shows.
                let lineTop = pill.frame.minY - (PillMetrics.line - PillMetrics.height) / 2 - InstructionEditor.inset.height
                clip.scroll(to: NSPoint(x: 0, y: max(0, min(lineTop, text.frame.height - clip.bounds.height))))
                scroll?.reflectScrolledClipView(clip)
                rect = frame()
            }
            parent.navigation.choice = ChoiceRequest(anchor: rect, bounds: content.bounds.size, naming: naming)
        }

        /// The pill's live view, laid over its attachment: the line's baseline less the pill's drop, at the
        /// attachment's x.
        func placePill() {
            guard let text, let layout = text.textLayoutManager, let content = layout.textContentManager else { return }
            let mark = (text.string as NSString).range(of: Action.choiceMark)
            guard mark.location != NSNotFound,
                  let location = content.location(content.documentRange.location, offsetBy: mark.location),
                  let fragment = layout.textLayoutFragment(for: location) else {
                pill?.removeFromSuperview()
                return
            }
            let paragraphStart = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
            let index = mark.location - paragraphStart
            guard let line = fragment.textLineFragments.first(where: { NSLocationInRange(index, $0.characterRange) }) else { return }
            let origin = text.textContainerOrigin
            let x = fragment.layoutFragmentFrame.minX + line.typographicBounds.minX + line.locationForCharacter(at: index).x
            let baseline = fragment.layoutFragmentFrame.minY + line.typographicBounds.minY + line.glyphOrigin.y
            let frame = CGRect(x: origin.x + x + PillMetrics.margin, y: origin.y + baseline - (PillMetrics.height - PillMetrics.drop),
                               width: PillMetrics.width(label), height: PillMetrics.height).integral
            let view = pill ?? makePill()
            if view.superview !== text { text.addSubview(view) }
            if view.frame != frame { view.frame = frame }
        }

        private func makePill() -> NSView {
            let root = AnyView(ChoicePill(library: parent.library, id: parent.id) { [weak self] in self?.togglePopover() }
                .environment(\.settingsStyle, parent.style))
            let view = NSHostingView(rootView: root)
            view.sizingOptions = []
            pill = view
            return view
        }
    }
}

/// Pastes plain words: the pill only comes from Insert a choice.
final class InstructionTextView: NSTextView {
    /// Puts the pill's view over its attachment after every layout.
    var placePill: () -> Void = {}
    /// Where a paste reads from.
    var pasteboard = NSPasteboard.general

    override func paste(_ sender: Any?) { pasteAsPlainText(sender) }

    override func pasteAsPlainText(_ sender: Any?) {
        guard let string = pasteboard.string(forType: .string) else { return }
        insertText(ActionInstruction.pasted(string), replacementRange: selectedRange())
    }

    override func layout() {
        super.layout()
        placePill()
    }

    /// The pill is a subview a text view doesn't report: listed here, VoiceOver and Accessibility clients reach it.
    override func accessibilityChildren() -> [Any]? {
        let pills = subviews.compactMap { $0 as? NSHostingView<AnyView> }.flatMap { $0.accessibilityChildren() ?? [] }
        return (super.accessibilityChildren() ?? []) + pills
    }
}
