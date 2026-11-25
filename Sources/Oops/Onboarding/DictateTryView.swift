import OopsCore
import SwiftUI

/// Try it's spoken beat: the same chat, a question from Léa, and Dictate's keys beneath it. While the speech model
/// is still downloading, its progress sits where the keys would be and the step unlocks when it lands.
struct DictateTryView: View {
    let step: DictateTryStep
    let fix: TryItStep
    let next: () -> Void
    /// Back to the Shortcut step, recording Dictate's keys again.
    let change: () -> Void

    var body: some View {
        OnboardingStepLayout(height: 430) { column } primary: {
            if step.isDone { OnboardingNextButton(title: "Continue", action: next).transition(.scale(scale: 0.9).combined(with: .opacity)) }
        } skip: {
            if !step.isDone { OnboardingSkipButton(action: next).transition(.opacity) }
        }
        .animation(.spring(duration: 0.45, bounce: 0.2), value: step.phase)
        .animation(.spring(duration: 0.45, bounce: 0.2), value: step.locked)
        .onAppear { step.start() }
        .onDisappear { step.stop() }
        .onChange(of: step.locked) { step.unlock() }
    }

    private var column: some View {
        VStack(spacing: 0) {
            Text(title).font(.system(size: 26, weight: .semibold)).monospacedDigit()
                .accessibilityAddTraits(.isHeader)
                .multilineTextAlignment(.center).lineLimit(2).frame(maxWidth: 620, minHeight: 34)
                .contentTransition(.numericText())
                .foregroundStyle(.white)
            TryItChat(step: fix, dictate: step).padding(.top, 24)
            // Under the keys without moving them; the step's own error style.
            keys.frame(height: 46).padding(.top, 26)
                .overlay(alignment: .bottom) {
                    if step.nothingArrived, step.phase == .waiting {
                        HStack(spacing: 12) {
                            Text("Nothing reached Oops. Another app may be using these keys.").font(.system(size: 13, weight: .medium)).opacity(0.85)
                            Button("Change shortcut", action: change).buttonStyle(.settingsGlass).controlSize(.small)
                        }
                        .foregroundStyle(.white).environment(\.colorScheme, .dark)
                        .fixedSize().offset(y: 44).transition(.opacity)
                    }
                }
        }
    }

    private var title: String {
        let label = step.keys.shortcut?.label ?? "your shortcut"
        switch step.phase {
        case .waiting: return "Hold \(label) and speak"
        case .listening: return "Listening"
        case let .done(words, seconds):
            let count = words == 1 ? "1 word" : "\(words) words"
            return seconds.map { "\(count) in \(TestEditorModel.seconds($0))" } ?? count
        case .unavailable: return "Hold \(label) to dictate in any app"
        }
    }

    @ViewBuilder private var keys: some View {
        if step.locked {
            VStack(spacing: 8) {
                Text("Speech model \(Int((step.speech.fraction * 100).rounded(.down)))%").font(.system(size: 13, weight: .medium)).monospacedDigit()
                    .contentTransition(.numericText())
                ProgressView(value: step.speech.fraction).tint(.white).frame(width: 260)
            }
            .foregroundStyle(.white)
            .environment(\.colorScheme, .dark)
            .accessibilityElement(children: .combine)
            .transition(.opacity)
        } else if !step.isDone {
            TryItKeys(caps: step.keys.keys, spoken: step.keys.spoken, pulsing: step.phase == .waiting)
                .foregroundStyle(.white)
                .environment(\.colorScheme, .dark)
                .transition(.opacity)
        }
    }
}

/// The spoken beat's composer: live, the real text view dictation writes into; acted, the answer as it arrives.
struct DictateTryComposer: View {
    let step: DictateTryStep

    var body: some View {
        if step.isLive, DebugFlags.setupSnapshots == nil {
            TryItEditor(model: step.fixture).frame(height: 78)
        } else {
            Text(verbatim: step.acted.isEmpty ? " " : step.acted).font(.system(size: 14)).foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 13).padding(.vertical, 8)
                .accessibilityLabel("Reply to Léa")
        }
    }
}
