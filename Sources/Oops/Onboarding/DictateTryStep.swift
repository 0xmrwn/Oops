import AppKit
import OopsCore
import SwiftUI

/// Try it's spoken beat, after Fix's or alone: Léa asks something, and the person answers by holding their Dictate
/// shortcut. It is the real dictation, written into a real text view, and the result is its own word count and
/// time. There is no replay: without the microphone or Accessibility the step only says how to dictate. A run that
/// saves nothing acts one, so the step can be looked at.
@MainActor @Observable final class DictateTryStep {
    enum Phase: Equatable { case waiting, listening, done(words: Int, seconds: Double?), unavailable }

    private(set) var phase = Phase.waiting
    private(set) var isLive = false
    /// The acted answer as it arrives.
    private(set) var acted = ""
    @ObservationIgnored let fixture = TestEditorModel()
    @ObservationIgnored let keys: ShortcutStep
    @ObservationIgnored let speech: OnboardingSpeechModel
    @ObservationIgnored private let preferences: Preferences?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var acting: Task<Void, Never>?
    /// What came before in the thread: Fix's reply, sent.
    @ObservationIgnored var earlier: [(text: String, sent: Bool)] = []
    /// Léa's next message, something to answer aloud; it follows the thread Fix's beat was in.
    @ObservationIgnored var question = "should I book for 8?"

    init(preferences: Preferences?, keys: ShortcutStep, speech: OnboardingSpeechModel) {
        self.preferences = preferences; self.keys = keys; self.speech = speech
        fixture.keptDraft = ""
    }

    var conversation: TryItStep.Conversation {
        TryItStep.Conversation(snippet: question, messages: earlier.suffix(2) + [(question, false)], draft: "")
    }
    var isDone: Bool {
        switch phase { case .done, .unavailable: true; default: false }
    }
    /// The model is still on its way: the keys wait behind its progress.
    var locked: Bool { phase == .waiting && speech.started && speech.phase != .ready }

    func start() {
        guard !started else { return }
        started = true
        guard preferences != nil else { return act() }
        let dictation = (NSApp.delegate as? AppDelegate)?.dictation
        isLive = dictation != nil && AXIsProcessTrusted() && DictationMicrophoneAccess.current == .granted && keys.shortcut != nil
            && ShortcutSettings.shared.shortcut(.dictate) != nil
        guard isLive else { phase = .unavailable; return }
        dictation?.onInserted = { [weak self] text, seconds in
            let words = text.split(whereSeparator: \.isWhitespace).count
            withAnimation(.spring(duration: 0.45, bounce: 0.2)) { self?.phase = .done(words: words, seconds: seconds) }
        }
        dictation?.onBusy = { [weak self] busy in
            // Nothing written (silence, Escape) asks again.
            guard let self, phase == (busy ? .waiting : .listening) else { return }
            withAnimation(.spring(duration: 0.4)) { self.phase = busy ? .listening : .waiting }
        }
        keys.mirror { false }
        unlock()
    }

    /// The real shortcut dictates only once there is a model to dictate with.
    func unlock() {
        guard started, isLive else { return }
        if locked { ShortcutSettings.shared.pause() } else { ShortcutSettings.shared.resume(); fixture.editor?.focus() }
    }

    func stop() {
        acting?.cancel(); acting = nil
        keys.stop()
        let dictation = (NSApp.delegate as? AppDelegate)?.dictation
        dictation?.onInserted = nil; dictation?.onBusy = nil
        if started { ShortcutSettings.shared.resume() }
        started = false
    }

    /// A run that saves nothing: the step hears the keys itself and plays an answer.
    private func act() {
        ShortcutSettings.shared.pause()
        keys.mirror { [weak self] in
            guard let self, phase == .waiting, !locked else { return true }
            withAnimation(.spring(duration: 0.4)) { phase = .listening }
            acting = Task { [weak self] in
                for word in "yes please, a large one".split(separator: " ") {
                    try? await Task.sleep(for: .milliseconds(230))
                    guard let self, !Task.isCancelled else { return }
                    acted += (acted.isEmpty ? "" : " ") + word
                }
                try? await Task.sleep(for: .milliseconds(400))
                guard let self, !Task.isCancelled else { return }
                withAnimation(.spring(duration: 0.45, bounce: 0.2)) { self.phase = .done(words: 5, seconds: nil) }
            }
            return true
        }
    }

    #if DEBUG
    func seed(_ phase: Phase, text: String = "") { self.phase = phase; acted = text }
    #endif
}
