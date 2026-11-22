import AppKit
import Observation
import OopsCore
import SwiftUI

/// Settings → Actions → Try: a draft of its own, run through the real action run (capture, model, write) and never
/// another app's field, and its status.
@Observable @MainActor final class ActionTryModel {
    static let shared = ActionTryModel()
    enum Status: Equatable { case ready, working, done(seconds: Double), restored, failed(ActionFailure) }
    private(set) var status = Status.ready
    /// The text before the last run while the draft still reads what the run wrote.
    private(set) var original: String?
    @ObservationIgnored private var written: String?
    @ObservationIgnored weak var editor: DraftEditorView?
    /// The draft while Try is closed: its text view goes with the panel.
    @ObservationIgnored var kept: String?
    /// Set by the app: focuses the draft, runs, and gives the outcome and the text the run committed; nil when
    /// Actions was busy.
    @ObservationIgnored var perform: (ActionInvocation) async -> ActionTryRun? = { _ in nil }

    var isWorking: Bool { status == .working }
    var canRestore: Bool { original != nil }

    /// Whether a run may read the draft: Try's own text view holds the keyboard in a key window. The session asks before
    /// it reads anything, so the name or instruction field, or another app's, is never taken for the draft.
    var draftIsFocused: Bool {
        guard let view = editor?.textView, let window = view.window, window.isKeyWindow, NSApp.isActive,
              window.firstResponder === view, view.accessibilityIdentifier() == DraftEditorView.actionTryIdentifier else { return false }
        return true
    }

    func run(_ action: Action, value: String?) async { await run(.saved(action, value: value)) }

    /// The drop's Try again comes here too, so the retry shows Working and Done and can be restored like any run.
    func retry(_ invocation: ActionInvocation) { Task { await run(invocation) } }

    func run(_ invocation: ActionInvocation) async {
        guard !isWorking, let before = editor?.text else { return }
        status = .working
        let started = ContinuousClock.now
        let result = await perform(invocation)
        let elapsed = started.duration(to: .now)
        switch result?.outcome {
        case .written?:
            // Restore is offered only for what the run committed, and only if the draft still reads exactly that: an
            // edit made after the write is the person's, and putting the old draft back would lose it.
            if let committed = result?.committed, let now = editor?.text, sameText(now, committed) {
                original = before
                written = committed
            } else {
                original = nil
                written = nil
            }
            status = .done(seconds: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
        case .failed(let failure)?: status = .failed(failure)
        case .held?: status = .failed(ActionFailure(.capture, "The draft changed while the action ran. Nothing was replaced."))
        case .cancelled?, .restored?, nil: status = .ready
        }
    }

    /// Puts the draft back as it was before the last run, through the text view's own undoable edit: offered while the
    /// draft still reads what the run wrote, which outlasts the drop's few seconds.
    func restore() {
        guard let original, let expected = written, let now = editor?.text, sameText(now, expected) else { return }
        editor?.replaceDraft(with: original)
        self.original = nil
        written = nil
        status = .restored
    }

    func textDidChange(_ text: String) {
        if written.map({ !sameText(text, $0) }) ?? true { original = nil; written = nil }
        if case .failed = status { status = .ready }
    }
}

/// What a Try run came to: its outcome, and the whole draft as the run left it when it wrote.
struct ActionTryRun {
    var outcome: ActionOutcome
    var committed: String?
}

/// Try's draft: the same text view Fix's Try uses, in its compact look and without taking focus on arrival.
struct ActionTryDraft: NSViewRepresentable {
    let model: ActionTryModel
    static let sample = "Write a summary of our Q3 results for the board. Keep it under one page and lead with cash position."

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> DraftEditorView {
        let view = DraftEditorView(initialText: model.kept ?? Self.sample, compact: true)
        view.textView.delegate = context.coordinator
        model.editor = view
        return view
    }

    func updateNSView(_ view: DraftEditorView, context: Context) {}

    static func dismantleNSView(_ view: DraftEditorView, coordinator: Coordinator) {
        coordinator.model.kept = view.text
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        let model: ActionTryModel
        init(model: ActionTryModel) { self.model = model }
        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            model.textDidChange(textView.string)
        }
    }
}

/// Try as Fix has it: a draft, its status line with the eyes, then Restore and Run. Run applies the action as it is
/// being edited.
struct ActionTryPanel: View {
    let store: ProviderStore
    let action: Action
    var model = ActionTryModel.shared
    @State private var value = ""

    /// What would run, with the value picked: Run needs words in it, however they got there (a choice may be all of it).
    private var invocation: ActionInvocation { .saved(action, value: values.isEmpty ? nil : picked) }
    private var values: [String] { action.choice?.ordered ?? [] }
    private var picked: String { values.contains(value) ? value : values.first ?? "" }
    private var done: Bool { if case .done = model.status { true } else { false } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(spacing: 0) {
                ActionTryDraft(model: model).frame(height: 104)
                status
            }
            .background(.primary.opacity(0.05), in: .rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.12)))
            buttons
        }
    }

    private var status: some View {
        HStack(spacing: 10) {
            OopsEyes(working: model.isWorking, check: done ? 1 : 0, ink: Color.primary.opacity(model.isWorking ? 0.9 : 0.72))
                .frame(width: 26, height: 26).accessibilityHidden(true)
            Text(message).font(.system(size: 12)).foregroundStyle(.primary.opacity(0.8)).monospacedDigit()
                .contentTransition(.opacity).animation(.easeOut(duration: 0.2), value: model.status)
                .accessibilityLabel("Try status").accessibilityValue(message)
            // A missing Accessibility grant is Settings' General page's to fix, not Providers'.
            if case .failed(let failure) = model.status, failure.reason != .capture, failure.label.remedy == .settings {
                Button("Providers") { store.wantsProvidersPage = true }.buttonStyle(.settingsGlass).controlSize(.small)
            }
            Spacer(minLength: 8)
        }
        .frame(minHeight: 26)
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private var buttons: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)
            if !values.isEmpty {
                GlassMenu(title: action.choice?.name.isEmpty == false ? action.choice?.name ?? "Choice" : "Choice",
                          choices: values.map { (value: $0, label: $0) }, selection: Binding(get: { picked }, set: { value = $0 }))
            }
            Button(action: model.restore) { Label("Restore original", systemImage: "arrow.uturn.backward") }
                .buttonStyle(.settingsGlass).controlSize(.large)
                .disabled(!model.canRestore || model.isWorking)
                .help("Put the draft back as it was before the last run")
            Button {
                Task { await model.run(invocation) }
            } label: { Label("Run", systemImage: SettingsTab.actions.symbol) }
                .buttonStyle(.glassProminent).tint(.accentColor).controlSize(.large)
                .disabled(model.isWorking || ActionPrompt.instruction(for: invocation).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Run this action on the draft")
        }
    }

    private var message: String {
        switch model.status {
        case .ready: " "
        case .working: "Working…"
        case .done(let seconds): "Done · " + TestEditorModel.seconds(seconds)
        case .restored: "Original restored"
        case .failed(let failure): failure.message
        }
    }
}
