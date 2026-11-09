import AppKit
import SwiftUI
import OopsCore

/// Hosts a real, focusable NSTextView: the correction flow captures and replaces
/// its text through Accessibility exactly like in Teams, Codex or Claude.
struct DraftEditor: NSViewRepresentable {
    @ObservedObject var model: TestEditorModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> DraftEditorView {
        let view = DraftEditorView(initialText: model.keptDraft ?? model.activeSample?.text ?? SampleDraft.typos.text)
        // Restore targeted the old text view, which is gone.
        if model.keptDraft != nil { model.restoreUnavailable() }
        view.textView.delegate = context.coordinator
        view.textView.onFocusChange = { [weak model] focused in model?.editorFocused = focused }
        model.editor = view
        return view
    }

    func updateNSView(_ view: DraftEditorView, context: Context) {
        context.coordinator.model = model
    }

    static func dismantleNSView(_ view: DraftEditorView, coordinator: Coordinator) {
        coordinator.model.keptDraft = view.text
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var model: TestEditorModel
        init(model: TestEditorModel) { self.model = model }
        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            model.textDidChange(textView.string)
        }
    }
}

final class DraftTextView: NSTextView {
    var onFocusChange: ((Bool) -> Void)?
    // Full-contrast glyphs on the glass pane: no vibrant blending of label ink.
    override var allowsVibrancy: Bool { false }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChange?(true) }
        return accepted
    }
    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { onFocusChange?(false) }
        return accepted
    }
}

/// Scroll view + text view, with a highlight layer *behind* the transparent text
/// so changed words glow under the glyphs instead of tinting them.
final class DraftEditorView: NSView {
    enum FlashStyle { case correction, restore }

    let textView: DraftTextView
    private let scrollView = NSScrollView()
    private let highlights = PassthroughView()
    private var flashGeneration = 0
    private var scrollObserver: NSObjectProtocol?

    var text: String { textView.string }

    init(initialText: String) {
        textView = DraftTextView(frame: NSRect(x: 0, y: 0, width: 560, height: 200))
        super.init(frame: .zero)
        configureTextView(initialText)
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = textView
        for view in [highlights, scrollView] as [NSView] {
            view.frame = bounds; view.autoresizingMask = [.width, .height]; addSubview(view)
        }
        highlights.wantsLayer = true
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.clearHighlights() } }
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    isolated deinit { if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) } }

    private func configureTextView(_ initialText: String) {
        let text = textView
        text.isRichText = false
        text.importsGraphics = false
        text.allowsUndo = true
        text.drawsBackground = false
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.minSize = NSSize(width: 0, height: 0)
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = true
        text.textContainerInset = NSSize(width: 16, height: 16)
        // Let oops do the correcting: no system spelling, quote, dash or text
        // substitutions that would mask what the pipeline does.
        text.isAutomaticSpellingCorrectionEnabled = false
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false
        text.isContinuousSpellCheckingEnabled = false
        text.isGrammarCheckingEnabled = false
        text.setAccessibilityIdentifier("oops-test-editor")
        text.setAccessibilityLabel("Draft")
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.22
        text.defaultParagraphStyle = paragraph
        text.typingAttributes = [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.textColor,
                                 .paragraphStyle: paragraph]
        text.font = .systemFont(ofSize: 15)
        text.textColor = .textColor
        text.string = initialText
        text.textStorage?.setAttributes(text.typingAttributes, range: NSRange(location: 0, length: (initialText as NSString).length))
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        window.initialFirstResponder = textView
        DispatchQueue.main.async { [weak self] in self?.focus() }
    }

    func focus() {
        guard let window, window.firstResponder !== textView else { return }
        FocusRingsWindow.placing = true
        defer { FocusRingsWindow.placing = false }
        window.makeFirstResponder(textView)
    }

    /// Undoable full replacement through the text view's own editing path.
    func replaceDraft(with newText: String) {
        clearHighlights()
        let full = NSRange(location: 0, length: (textView.string as NSString).length)
        guard textView.shouldChangeText(in: full, replacementString: newText) else { return }
        textView.textStorage?.replaceCharacters(in: full, with: NSAttributedString(string: newText, attributes: textView.typingAttributes))
        textView.didChangeText()
        textView.undoManager?.setActionName("Sample Draft")
        textView.setSelectedRange(NSRange(location: (newText as NSString).length, length: 0))
        textView.scrollToBeginningOfDocument(nil)
        // A brief settle-in fade (no movement, so it also suits Reduce Motion).
        textView.alphaValue = 0.35
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            textView.animator().alphaValue = 1
        }
    }

    // MARK: Highlights

    func flash(_ ranges: [NSRange], style: FlashStyle) {
        clearHighlights()
        flashGeneration += 1
        let generation = flashGeneration
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        var color = NSColor.clear
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            color = style == .correction
                ? NSColor.controlAccentColor.withAlphaComponent(dark ? 0.45 : 0.3)
                : NSColor.labelColor.withAlphaComponent(dark ? 0.2 : 0.12)
        }
        let rects = ranges.flatMap { rects(for: $0) }.prefix(200)
        let duration = ResultTiming.flash
        for (index, rect) in rects.enumerated() {
            let pill = NSView(frame: rect)
            pill.wantsLayer = true
            let shape = CALayer()
            shape.frame = pill.bounds
            shape.cornerRadius = min(rect.height / 2, 6)
            shape.cornerCurve = .continuous
            effectiveAppearance.performAsCurrentDrawingAppearance { shape.backgroundColor = color.cgColor }
            shape.opacity = 0
            pill.layer?.addSublayer(shape)
            highlights.addSubview(pill)
            let delay = reduceMotion ? 0 : min(Double(index) * 0.04, 0.32)
            let begin = CACurrentMediaTime() + delay
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0, 1, 1, 0]
            fade.keyTimes = [0, 0.1, 0.5, 1]
            fade.duration = duration
            fade.beginTime = begin
            fade.fillMode = .both
            shape.add(fade, forKey: "fade")
            if !reduceMotion {
                let pop = CASpringAnimation(keyPath: "transform.scale")
                pop.fromValue = 0.82; pop.toValue = 1
                pop.damping = 14; pop.stiffness = 260; pop.mass = 0.8
                pop.duration = pop.settlingDuration
                pop.beginTime = begin
                pop.fillMode = .backwards
                shape.add(pop, forKey: "pop")
            }
        }
        let total = duration + (reduceMotion ? 0 : 0.35) + 0.1
        DispatchQueue.main.asyncAfter(deadline: .now() + total) { [weak self] in
            guard let self, self.flashGeneration == generation else { return }
            self.clearHighlights()
        }
    }

    func clearHighlights() {
        highlights.subviews.forEach { $0.removeFromSuperview() }
    }

    /// Segment rects for a UTF-16 range, in this view's coordinates. Empty
    /// ranges (pure deletions) become a slim marker at the deletion point.
    private func rects(for range: NSRange) -> [CGRect] {
        let length = (textView.string as NSString).length
        guard range.location <= length, NSMaxRange(range) <= length else { return [] }
        var segments: [CGRect] = []
        if let layout = textView.textLayoutManager, let content = layout.textContentManager {
            let docStart = content.documentRange.location
            guard let start = content.location(docStart, offsetBy: range.location),
                  let end = content.location(start, offsetBy: range.length),
                  let textRange = NSTextRange(location: start, end: end) else { return [] }
            layout.ensureLayout(for: textRange)
            layout.enumerateTextSegments(in: textRange, type: range.length == 0 ? .selection : .highlight,
                                         options: [.rangeNotRequired]) { _, frame, _, _ in
                segments.append(frame); return true
            }
        } else if let manager = textView.layoutManager, let container = textView.textContainer {
            let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            manager.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                            in: container) { rect, _ in segments.append(rect) }
        }
        let origin = textView.textContainerOrigin
        let font = NSFont.systemFont(ofSize: 15)
        let glyphHeight = ceil(font.ascender - font.descender) + 3
        return segments.map { segment in
            var rect = segment.offsetBy(dx: origin.x, dy: origin.y)
            // Line height multiple adds its space above the glyphs: hug the
            // glyph box at the bottom of the fragment, descenders included.
            if rect.height > glyphHeight {
                rect.origin.y = rect.maxY - glyphHeight + 1.5; rect.size.height = glyphHeight
            }
            if range.length == 0 { rect.origin.x -= 1.5; rect.size.width = 3 }
            else { rect = rect.insetBy(dx: -3, dy: 0) }
            return textView.convert(rect, to: highlights)
        }
    }
}

private final class PassthroughView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
