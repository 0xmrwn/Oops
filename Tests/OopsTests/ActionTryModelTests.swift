import Foundation
@testable import Oops
import OopsCore
import Testing

/// Settings' Try: what its status and Restore say after a run, with the run itself standing in.
@MainActor struct ActionTryModelTests {
    /// `committed` is what the run reports it wrote; `editedAfter` is typed into the draft in the gap after the write.
    private func model(draft: String, outcome: ActionOutcome?, writes answer: String? = nil, committed: String? = nil,
                       editedAfter: String? = nil) -> ActionTryModel {
        let model = ActionTryModel()
        let editor = DraftEditorView(initialText: draft, compact: true)
        model.editor = editor
        model.perform = { _ in
            if let answer { editor.replaceDraft(with: answer) }
            if let editedAfter { editor.replaceDraft(with: editedAfter) }
            return outcome.map { ActionTryRun(outcome: $0, committed: committed ?? answer) }
        }
        return model
    }

    private let action = Action(symbol: "sparkles", name: "Tidy", instruction: "Tidy it.", place: .up)

    @Test func `a written run is done and can be restored`() async {
        let model = model(draft: "before", outcome: .written, writes: "after")
        await model.run(action, value: nil)
        guard case .done = model.status else { Issue.record("expected done, got \(model.status)"); return }
        #expect(model.canRestore)
        model.restore()
        #expect(model.editor?.text == "before")
        #expect(model.status == .restored)
        #expect(!model.canRestore)
    }

    @Test func `editing the draft after a run withdraws Restore`() async {
        let model = model(draft: "before", outcome: .written, writes: "after")
        await model.run(action, value: nil)
        model.textDidChange("after, edited")
        #expect(!model.canRestore)
        model.restore()
        #expect(model.status != .restored)
    }

    @Test func `a failed run shows why and clears when the draft changes`() async {
        let failure = ActionFailure(.model, "The model could not answer.")
        let model = model(draft: "before", outcome: .failed(failure))
        await model.run(action, value: nil)
        #expect(model.status == .failed(failure))
        model.textDidChange("before!")
        #expect(model.status == .ready)
    }

    @Test func `a run Actions was too busy to start leaves Try ready`() async {
        let model = model(draft: "before", outcome: nil)
        await model.run(action, value: nil)
        #expect(model.status == .ready)
        #expect(!model.canRestore)
    }

    @Test func `an edit made after the write is not undone by Restore`() async {
        let model = model(draft: "before", outcome: .written, writes: "after", committed: "after", editedAfter: "after, and mine")
        await model.run(action, value: nil)
        #expect(!model.canRestore)
        model.restore()
        #expect(model.editor?.text == "after, and mine")
    }

    @Test func `a retry runs through Try and can be restored`() async throws {
        let model = model(draft: "before", outcome: .written, writes: "again")
        model.retry(.saved(action, value: nil))
        for _ in 0..<100 where model.status == .ready || model.isWorking { try await Task.sleep(for: .milliseconds(10)) }
        guard case .done = model.status else { Issue.record("expected done, got \(model.status)"); return }
        #expect(model.canRestore)
    }

    @Test func `no draft is focused without a key window`() {
        let model = ActionTryModel()
        #expect(!model.draftIsFocused)
        let editor = DraftEditorView(initialText: "text", compact: true)
        model.editor = editor
        #expect(!model.draftIsFocused)
        #expect(editor.textView.accessibilityIdentifier() == DraftEditorView.actionTryIdentifier)
    }
}
