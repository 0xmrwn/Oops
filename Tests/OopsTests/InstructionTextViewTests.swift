import AppKit
@testable import Oops
import OopsCore
import Testing

/// What the instruction's text view takes from a paste.
@MainActor struct InstructionTextViewTests {
    @Test func `a pasted object replacement character inserts no pill`() {
        let board = NSPasteboard(name: NSPasteboard.Name("oops-instruction-" + UUID().uuidString))
        defer { board.releaseGlobally() }
        board.clearContents()
        board.setString("a\(Action.choiceMark)b", forType: .string)
        let view = InstructionTextView(usingTextLayoutManager: true)
        view.pasteboard = board
        view.paste(nil)
        #expect(view.string == "ab")
    }
}
