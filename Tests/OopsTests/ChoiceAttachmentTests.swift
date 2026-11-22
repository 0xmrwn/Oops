import AppKit
@testable import Oops
import OopsCore
import Testing

/// The room the text leaves for the choice's pill follows its name.
@MainActor struct ChoiceAttachmentTests {
    @Test func `the reserved width follows the label`() {
        let attachment = ChoiceAttachment(label: "Tone")
        let short = attachment.reservedWidth
        #expect(short == PillMetrics.width("Tone") + 2 * PillMetrics.margin)
        attachment.resize(to: "A much longer name", in: InstructionTextView(usingTextLayoutManager: true))
        #expect(attachment.reservedWidth > short)
        attachment.resize(to: "", in: InstructionTextView(usingTextLayoutManager: true))
        #expect(attachment.reservedWidth == PillMetrics.width("") + 2 * PillMetrics.margin)
    }

    /// Where the text after the pill starts, on its line.
    private func textStart(_ text: InstructionTextView) -> CGFloat? {
        guard let manager = text.textLayoutManager else { return nil }
        manager.ensureLayout(for: manager.documentRange)
        var x: CGFloat?
        manager.enumerateTextLayoutFragments(from: manager.documentRange.location, options: []) { fragment in
            x = fragment.textLineFragments.first.map { $0.typographicBounds.minX + $0.locationForCharacter(at: 1).x }
            return false
        }
        return x
    }

    @Test func `the text after the pill moves when the label changes`() {
        let text = InstructionTextView(usingTextLayoutManager: true)
        text.frame = NSRect(x: 0, y: 0, width: 400, height: 100)
        let attachment = ChoiceAttachment(label: "")
        let content = NSMutableAttributedString(string: "\(Action.choiceMark)tail", attributes: InstructionText.Coordinator.base)
        content.addAttribute(.attachment, value: attachment, range: NSRange(location: 0, length: 1))
        text.textStorage?.setAttributedString(content)
        let unnamed = textStart(text)
        attachment.resize(to: "A much longer name", in: text)
        let longer = textStart(text)
        attachment.resize(to: "", in: text)
        let cleared = textStart(text)
        #expect(unnamed != nil)
        #expect((longer ?? 0) > (unnamed ?? .infinity))
        #expect(cleared == unnamed)
    }
}
