import AppKit
@testable import Oops
import Testing

@MainActor struct SkillTokensTests {
    private func storage(_ text: String) -> NSTextStorage {
        NSTextStorage(string: text, attributes: InstructionText.Coordinator.base)
    }

    private func marked(_ storage: NSTextStorage) -> [String] {
        var found: [String] = []
        storage.enumerateAttribute(.oopsSkillToken, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if value != nil { found.append((storage.string as NSString).substring(with: range)) }
        }
        return found
    }

    @Test func `known skills with either sigil are tokens and anything else stays plain`() {
        let storage = storage("Use /review and $review, not /reviewer or $other or a/review.")
        #expect(SkillTokens.apply(to: storage, names: ["review"]))
        #expect(marked(storage) == ["/review", "$review"])
        // The words keep the text's own colour; the highlight is drawn behind them.
        let range = (storage.string as NSString).range(of: "/review")
        #expect(storage.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor == .textColor)
    }

    @Test func `applying again changes nothing, and no names clear every token`() {
        let storage = storage("Run $review now")
        SkillTokens.apply(to: storage, names: ["review"])
        #expect(!SkillTokens.apply(to: storage, names: ["review"]))
        #expect(SkillTokens.apply(to: storage, names: []))
        #expect(marked(storage).isEmpty)
        #expect(storage.string == "Run $review now")
    }

    @Test func `editing a token's name unmarks it and the text stays what was typed`() {
        let storage = storage("Run $review now")
        SkillTokens.apply(to: storage, names: ["review"])
        storage.replaceCharacters(in: NSRange(location: 11, length: 0), with: "x")
        SkillTokens.apply(to: storage, names: ["review"])
        #expect(marked(storage).isEmpty)
        #expect(storage.string == "Run $reviewx now")
    }

    @Test func `the choice's attachment character is never part of a token`() {
        let storage = storage("\u{FFFC}/review \u{FFFC}")
        SkillTokens.apply(to: storage, names: ["review"])
        #expect(marked(storage).isEmpty)
        let spaced = self.storage("Make it \u{FFFC} with /review")
        SkillTokens.apply(to: spaced, names: ["review"])
        #expect(marked(spaced) == ["/review"])
    }

    @Test func `a paragraph with a token lays out as the token fragment`() {
        let text = InstructionTextView(usingTextLayoutManager: true)
        let layout = SkillTokenLayout()
        text.frame = NSRect(x: 0, y: 0, width: 300, height: 100)
        text.textLayoutManager?.delegate = layout
        text.textStorage?.setAttributedString(NSAttributedString(string: "Plain line\nUse /review here", attributes: InstructionText.Coordinator.base))
        if let storage = text.textStorage { SkillTokens.apply(to: storage, names: ["review"]) }
        guard let manager = text.textLayoutManager else { Issue.record("no layout manager"); return }
        manager.ensureLayout(for: manager.documentRange)
        var kinds: [Bool] = []
        manager.enumerateTextLayoutFragments(from: manager.documentRange.location, options: []) { fragment in
            kinds.append(fragment is SkillTokenFragment)
            return true
        }
        #expect(kinds == [false, true])
        #expect(manager.delegate === layout)
    }
}
