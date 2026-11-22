import AppKit
import OopsCore

/// The skill names offered while the person types a `/` or `$` at a word start in the instruction. The text view stays
/// first responder throughout: its delegate hands the arrow, Return, Tab and Escape commands here while the list shows.
@MainActor final class SkillSuggestions {
    private let model = SkillSuggestionModel()
    private var panel: SkillSuggestionPanel?
    private var completion: SkillCompletion?
    private weak var textView: NSTextView?

    private nonisolated(unsafe) var scrollObserver: any NSObjectProtocol?

    var isShowing: Bool { panel?.isVisible == true }

    init() {
        // The list is placed on the screen, so a page that scrolls under it leaves it behind: it closes.
        scrollObserver = NotificationCenter.default.addObserver(forName: .settingsPageDidScroll, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
    }

    deinit { scrollObserver.map(NotificationCenter.default.removeObserver) }

    /// Follows the caret: shows the names that fit what is typed, or hides the list when nothing is being typed or
    /// nothing fits.
    func update(in textView: NSTextView, names: [String]) {
        let selection = textView.selectedRange()
        guard !names.isEmpty, selection.length == 0, textView.window?.firstResponder === textView,
              let found = ClaudeSkills.completion(in: textView.string, caret: selection.location) else { return hide() }
        let matches = ClaudeSkills.suggestions(found.partial, from: names)
        // A name typed out in full has nothing left to offer.
        guard !matches.isEmpty, !found.isTyped(in: matches) else { return hide() }
        self.textView = textView
        let keep = completion == found && model.names == matches
        completion = found
        model.sigil = found.sigil
        if model.names != matches {
            let current = model.highlighted < model.names.count ? model.names[model.highlighted] : nil
            model.names = matches
            model.highlighted = current.flatMap(matches.firstIndex(of:)) ?? 0
        }
        if !keep || !isShowing { place(for: textView, found) }
    }

    /// Whether the command belonged to the list: Up and Down move the highlight, Return and Tab take the lit name,
    /// Escape closes.
    func handle(_ selector: Selector) -> Bool {
        guard isShowing, !model.names.isEmpty else { return false }
        switch selector {
        case #selector(NSResponder.moveUp(_:)): model.highlighted = (model.highlighted - 1 + model.names.count) % model.names.count
        case #selector(NSResponder.moveDown(_:)): model.highlighted = (model.highlighted + 1) % model.names.count
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)): accept(model.names[model.highlighted])
        case #selector(NSResponder.cancelOperation(_:)): hide()
        default: return false
        }
        return true
    }

    /// The list follows its text when the text scrolls.
    func reposition() {
        if isShowing, let textView, let completion { place(for: textView, completion) }
    }

    func hide() {
        completion = nil
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    /// Writes the name over what was typed: the sigil the person used, the name and a space.
    private func accept(_ name: String) {
        guard let textView, let completion else { return hide() }
        hide()
        textView.insertText(completion.replacement(for: name), replacementRange: completion.range)
    }

    /// Under the sigil's line, or above it when the screen has no room below.
    private func place(for textView: NSTextView, _ found: SkillCompletion) {
        guard let window = textView.window else { return }
        let panel = panel ?? SkillSuggestionPanel(model: model) { [weak self] in self?.accept($0) }
        self.panel = panel
        let size = NSSize(width: SkillSuggestionList.width, height: SkillSuggestionList.height(rows: model.names.count))
        let line = textView.firstRect(forCharacterRange: NSRange(location: found.range.location, length: 0), actualRange: nil)
        var origin = NSPoint(x: line.minX - SkillSuggestionList.padding - 10, y: line.minY - size.height - 4)
        if let visible = window.screen?.visibleFrame {
            if origin.y < visible.minY { origin.y = line.maxY + 4 }
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        }
        panel.appearance = window.effectiveAppearance
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        if panel.parent !== window { window.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
    }
}
