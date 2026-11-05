import AppKit
import Combine
import OopsCore
import SwiftUI

/// Onboarding's Try it step: a reply waiting in a chat composer, corrected by the person's own
/// shortcut. Live, it is a real text view the whole pipeline captures and replaces, like any app's
/// (capture, provider, drop, flash, sound), and the result is the provider's own. Without a provider
/// or Accessibility (or in a `--hello-only` run), it replays Hello's first scene instead, whose
/// answer is a recorded pipeline output, and claims no time. Pressed again, either way, the shortcut
/// restores the reply, and once more puts the fix back (D10).
@MainActor @Observable final class TryItStep {
    enum Phase: Equatable { case ready, working, fixed(changes: Int, seconds: Double?), restored, clear, failed(String) }

    /// A chat thread and the reply waiting in it.
    struct Conversation {
        let snippet: String
        let messages: [(text: String, sent: Bool)]
        let draft: String
    }

    /// Dinner plans, with the slips of typing fast: you're for your, a doubled letter, a dropped
    /// one, a swapped pair.
    static let live = Conversation(snippet: "where do you want to go?",
                                   messages: [("still on for dinner tomorrow?", false), ("yes!", true), ("where do you want to go?", false)],
                                   draft: "that ramen place near you're work? i can be there arround 8, might be a few minuts late, my last meeting tends to run ovre")
    /// Hello's first scene, and its recorded answer.
    static let replay = Conversation(snippet: "where are you?? movie…",
                                     messages: [("grabbing popcorn?", true), ("where are you?? movie starts in 10", false)],
                                     draft: HelloDraft.typed.before)

    private(set) var isLive = false
    private(set) var phase = Phase.ready
    private(set) var recording = false
    /// The replay's text and the words it flashes.
    private(set) var replayText = TryItStep.replay.draft
    private(set) var replayFlash: [NSRange] = []

    /// Live drafts report here: the session hands its outcome to the Try surface in front.
    @ObservationIgnored let fixture = TestEditorModel()
    @ObservationIgnored let shortcuts: ShortcutStep
    @ObservationIgnored private let preferences: Preferences?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var status: AnyCancellable?
    @ObservationIgnored private var replaying: Task<Void, Never>?

    init(preferences: Preferences?, shortcuts: ShortcutStep) {
        self.preferences = preferences; self.shortcuts = shortcuts
        fixture.keptDraft = Self.live.draft
    }

    var conversation: Conversation { isLive ? Self.live : Self.replay }
    var isDone: Bool {
        switch phase { case .fixed, .restored, .clear: true; default: false }
    }

    // MARK: Listening

    func start() {
        guard !started else { return }
        #if DEBUG
        // Offscreen snapshots seed their own moment.
        if DebugFlags.setupSnapshots != nil { return }
        #endif
        started = true
        // Decided once, here: the steps before may just have granted Accessibility or added a provider.
        isLive = preferences.map {
            AXIsProcessTrusted() && !DebugFlags.missingAccessibility && $0.providers.selectedIsReady && (try? $0.providers.backend()) != nil
        } ?? false
        if isLive {
            status = fixture.$status.sink { [weak self] in self?.follow($0) }
            ShortcutSettings.shared.resume()
        } else {
            // The shortcut can't correct here: the step hears it itself, and it doesn't reach another app.
            ShortcutSettings.shared.pause()
        }
        mirror()
        let window = NSApp.windows.first { $0.identifier == ShortcutStep.window }
        let center = NotificationCenter.default
        observers = [
            // Elsewhere the shortcut corrects as usual; back here the draft has the focus again, and a
            // replay hears the keys itself.
            center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.windowBecameKey() }
            },
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if self?.isLive == false { ShortcutSettings.shared.resume() } }
            },
        ]
    }

    func stop() {
        replaying?.cancel(); replaying = nil
        observers.forEach(NotificationCenter.default.removeObserver); observers = []
        status = nil
        shortcuts.stop(); recording = false
        if started { ShortcutSettings.shared.resume() }
        started = false
    }

    private func windowBecameKey() {
        if isLive { fixture.editor?.focus() } else if !recording { ShortcutSettings.shared.pause() }
    }

    /// The pipeline's report on the live draft, as the step's phase.
    private func follow(_ status: TestEditorModel.Status) {
        let next: Phase = switch status {
        case .ready: .ready
        case .restored: .restored
        case .working: .working
        case let .corrected(changes, seconds): .fixed(changes: changes, seconds: seconds)
        case .alreadyClear: .clear
        case let .failed(message, _): .failed(message)
        }
        guard next != phase else { return }
        withAnimation(.spring(duration: 0.45, bounce: 0.2)) { phase = next }
    }

    // MARK: Replay

    /// The keys beneath the draft light as they go down, through the Shortcut step's listener. Live,
    /// the hotkey corrects and the step only watches; replaying, the step takes the shortcut itself.
    private func mirror() {
        shortcuts.mirror { [weak self] in
            guard let self, !isLive else { return false }
            playReplay()
            return true
        }
    }

    /// What the shortcut does in the replay, while its window is in front (also a lab trigger's): fixes the
    /// reply, then restores it and puts the fix back, as it does a live one.
    func playReplay() {
        guard !isLive, NSApp.keyWindow?.identifier == ShortcutStep.window else { return }
        switch phase {
        case .fixed: return swapReplay(to: Self.replay.draft, from: HelloDraft.typed.after, phase: .restored)
        case .restored:
            let diff = WordDiff(before: Self.replay.draft, after: HelloDraft.typed.after)
            return swapReplay(to: HelloDraft.typed.after, from: Self.replay.draft, phase: .fixed(changes: diff.changes, seconds: nil))
        case .ready: break
        default: return
        }
        withAnimation(.spring(duration: 0.4)) { phase = .working }
        Sounds.shared.play(.start, after: 0)
        replaying = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.1))
            guard let self, !Task.isCancelled else { return }
            let after = HelloDraft.typed.after
            let diff = WordDiff(before: Self.replay.draft, after: after)
            withAnimation(.easeOut(duration: 0.25)) { replayText = after; replayFlash = diff.afterRanges }
            withAnimation(.spring(duration: 0.45, bounce: 0.2)) { phase = .fixed(changes: diff.changes, seconds: nil) }
            Sounds.shared.play(.success, after: 0)
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                 userInfo: [.announcement: TestEditorModel.fixesLabel(diff.changes), .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        }
    }

    /// The replay's restore or re-apply: instant, as the live one is, with the words it changed flashed.
    private func swapReplay(to text: String, from previous: String, phase next: Phase) {
        let restoring = next == .restored
        withAnimation(.easeOut(duration: 0.25)) { replayText = text; replayFlash = WordDiff(before: previous, after: text).afterRanges }
        withAnimation(.spring(duration: 0.45, bounce: 0.2)) { phase = next }
        if !restoring { Sounds.shared.play(.success, after: 0) }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: restoring ? "Original restored" : "Fix put back",
                                        .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    // MARK: Changing the shortcut

    /// Change, from the Shortcut step's own recorder: it listens only while recording, then the
    /// hotkeys come back (live) or stay with the replay.
    func change() {
        guard !recording else { return }
        recording = true
        shortcuts.start()
        shortcuts.change()
        watchRecorder()
    }

    func cancelChange() { shortcuts.cancelRecording() }

    private func watchRecorder() {
        withObservationTracking { _ = shortcuts.phase } onChange: { [weak self] in
            Task { @MainActor in self?.recorderChanged() }
        }
    }

    private func recorderChanged() {
        guard recording else { return }
        guard shortcuts.phase != .recording else { return watchRecorder() }
        shortcuts.stop()
        recording = false
        mirror()
        if isLive { fixture.editor?.focus() } else { ShortcutSettings.shared.pause() }
    }

    #if DEBUG
    /// Sets a moment directly, for `-SetupSnapshots`: the replay's composer, before or after.
    func seed(_ phase: Phase, live: Bool = true, text: String? = nil, flashed: [String] = []) {
        self.phase = phase; isLive = live
        replayText = text ?? (live ? Self.live : Self.replay).draft
        replayFlash = flashed.map { (replayText as NSString).range(of: $0) }.filter { $0.location != NSNotFound }
    }
    #endif
}
