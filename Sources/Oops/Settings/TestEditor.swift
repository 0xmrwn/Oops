import AppKit
import SwiftUI
import OopsCore

/// State for Settings → General → Try, the local test editor. The correction itself always runs through
/// AppDelegate's real pipeline (Accessibility capture, provider call, native
/// paste), so this model only mirrors what that pipeline reports.
@MainActor final class TestEditorModel: ObservableObject {
    enum Remedy: Equatable {
        case settings, accessibility
        var title: String { self == .settings ? "Open Settings" : "Open Accessibility" }
    }
    enum Status: Equatable {
        case ready
        case working
        /// No time for a fix put back from memory.
        case corrected(changes: Int, seconds: Double?)
        case alreadyClear(seconds: Double)
        case restored
        case failed(message: String, remedy: Remedy?)
    }

    @Published private(set) var status: Status = .ready
    @Published private(set) var canRestore = false
    @Published private(set) var activeSample: SampleDraft? = .typos
    @Published var canCancel = true
    @Published var busy = false
    @Published var editorFocused = false
    /// Something outside Settings (the menu, `--fixture`, the perf harness) asks for the Try page.
    @Published var requested = false
    /// The Try page is what Settings shows: Fix and Restore then target its draft.
    var presented = false
    /// The draft while the Try page is closed: its text view goes with the page and a new one
    /// starts from this, not from a sample.
    var keptDraft: String?

    var onCorrect: () -> Void = {}
    var onRestore: () -> Void = {}
    var onOpenSettings: () -> Void = {}
    weak var editor: DraftEditorView?
    /// The full draft right after the last correction landed here. Restore is
    /// offered only while the draft still matches it, as the session requires.
    private var restorableText: String?

    var isWorking: Bool { status == .working }

    // Pipeline events
    func began() { status = .working }
    func cancelled() { if status == .working { status = .ready } }
    func failed(_ message: String, remedy: Remedy?) {
        status = .failed(message: message, remedy: remedy)
        announce(message)
    }
    func alreadyClear(seconds: Double) {
        status = .alreadyClear(seconds: seconds)
        announce("Already clear")
    }
    func corrected(before: String, expected: String, seconds: Double?) {
        let current = editor?.text
        let after = current.map { sameText($0, expected) } == true ? current! : expected
        let diff = WordDiff(before: before, after: after)
        restorableText = after
        canRestore = true
        status = .corrected(changes: diff.changes, seconds: seconds)
        if current.map({ sameText($0, after) }) == true { editor?.flash(diff.afterRanges, style: .correction) }
        announce(Self.fixesLabel(diff.changes))
    }
    func restored(corrected: String, original: String) {
        restorableText = nil
        canRestore = false
        status = .restored
        if let current = editor?.text, sameText(current, original) {
            editor?.flash(WordDiff(before: corrected, after: original).afterRanges, style: .restore)
        }
        announce("Original restored")
    }
    func restoreUnavailable() { restorableText = nil; canRestore = false }

    // Editor events
    func textDidChange(_ text: String) {
        canRestore = restorableText.map { sameText($0, text) } ?? false
        if activeSample.map({ sameText($0.text, text) }) != true {
            activeSample = SampleDraft.allCases.first { sameText($0.text, text) }
        }
        if case .failed = status { status = .ready }
    }
    func load(_ sample: SampleDraft) {
        guard !busy else { return }
        editor?.replaceDraft(with: sample.text)
        activeSample = sample
        if !isWorking { status = .ready }
        editor?.focus()
    }
    func openRemedy(_ remedy: Remedy) {
        switch remedy {
        case .settings: onOpenSettings()
        case .accessibility:
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
    }

    /// Shared with the capsule, so both surfaces word an outcome the same way.
    static func fixesLabel(_ count: Int) -> String { count == 1 ? "1 fix" : "\(count) fixes" }
    static func seconds(_ value: Double) -> String { String(format: "%.1fs", value) }

    private func announce(_ message: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }
}

// MARK: - Samples

enum SampleDraft: String, CaseIterable, Identifiable {
    case typos = "Typos", french = "Français", mixed = "Mixed", code = "Code & links"
    var id: Self { self }
    var symbol: String {
        switch self {
        case .typos: "textformat.abc"
        case .french: "globe.europe.africa"
        case .mixed: "text.bubble"
        case .code: "chevron.left.forwardslash.chevron.right"
        }
    }
    var text: String {
        switch self {
        case .typos:
            "hey, i just pushed the fix for the login bug. it shoud work now but can you double check on your side befor we ship it ? also teh docs need a small update, ill do it after lunch"
        case .french:
            "salut ! j'ai regarder le bug hier soir et je pense que sa vient du cache. on peux en parler apres le stand-up si t'as 5 min, sinon demain matin sa me va aussi"
        case .mixed:
            "ok donc le deploy de staging a fail cette nuit, surement le healthcheck qui timeout trop vite. i'll bump it to 30s et je relance, tell me si tu vois un truc bizzare sur les dashbords"
        case .code:
            // Protected spans sit in a clean first line, so the edited span never
            // crosses code or a mention (the native paste path refuses that).
            "Quick update for @sami: the fix for https://github.com/0xmrwn/oops/pull/42 is in `RetryPolicy.swift`.\nit solves the timout on slow networks but theres still a flaky test when the token expirs. i'll look at it tomorow morning, dont merge yet pls"
        }
    }
}
