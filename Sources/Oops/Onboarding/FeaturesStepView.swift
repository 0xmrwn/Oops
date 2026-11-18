import OopsCore
import SwiftUI

/// The choice step over Hello's wallpaper: a glass row per feature with the switch that turns it on. A
/// row shows its feature at work rather than describing it.
struct FeaturesStepView: View {
    let step: FeaturesStep
    let next: () -> Void
    /// The rows' demos turn over together: a sloppy draft and a voice, then the fix and the words.
    @State private var settled = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.onboardingEffectsVisible) private var visible

    var body: some View {
        let moving = visible && !reduceMotion
        OnboardingStepLayout(height: 400) { column } primary: {
            if !step.chosen.isEmpty {
                OnboardingNextButton(title: "Continue", action: next).transition(.scale(scale: 0.9).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.5, bounce: 0.3), value: step.chosen.isEmpty)
        .task(id: moving) {
            // Still, the rows rest on what each feature leaves behind.
            guard moving else { settled = true; return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(settled ? 2.4 : 1.6))
                withAnimation(.easeInOut(duration: 0.3)) { settled.toggle() }
            }
        }
    }

    private var column: some View {
        VStack(spacing: 0) {
            Color.clear.frame(width: 84, height: 84)
                .anchorPreference(key: OnboardingDropKey.self, value: .bounds) { ["step": $0] }
            Text("What should Oops do?").font(.system(size: 26, weight: .semibold)).padding(.top, 20)
            GlassEffectContainer(spacing: 14) {
                VStack(spacing: 14) { ForEach(OnboardingFeature.allCases, id: \.self, content: row) }
            }
            .padding(.top, 34)
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }

    private func row(_ feature: OnboardingFeature) -> some View {
        let isOn = step.chosen.contains(feature)
        return Toggle(isOn: Binding(get: { isOn }, set: { _ in step.toggle(feature) })) {
            HStack(spacing: 18) {
                Text(feature.title).font(.system(size: 21, weight: .semibold)).frame(width: 96, alignment: .leading)
                Group {
                    switch feature {
                    case .fix: FixDemo(fixed: settled)
                    case .dictate: DictateDemo(spoken: settled, moving: visible && !reduceMotion)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(isOn ? 1 : 0.35)
                .accessibilityHidden(true)
            }
            .shadow(color: .black.opacity(0.35), radius: 3)
        }
        // White ink like Home's switch: the accent colour would be the only colour Oops adds to the step.
        .toggleStyle(.switch).controlSize(.large).tint(.white.opacity(0.85))
        .padding(.horizontal, 24)
        .frame(width: 560, height: 92)
        .contentShape(.rect(cornerRadius: 24))
        .onTapGesture { step.toggle(feature) }
        .glassEffect(.clear.tint(.white.opacity(isOn ? 0.12 : 0)), in: .rect(cornerRadius: 24))
        .animation(.spring(duration: 0.3), value: isOn)
    }
}

/// Hello's own typed draft, sloppy and then fixed with its changed words lit: a real correction.
private struct FixDemo: View {
    let fixed: Bool

    var body: some View {
        Text(text).font(.system(size: 15, weight: .medium)).lineLimit(1).minimumScaleFactor(0.75)
            .contentTransition(.opacity)
    }

    private var text: AttributedString {
        let draft = HelloDraft.typed
        var text = AttributedString(fixed ? draft.after : draft.before)
        guard fixed else { return text }
        for range in draft.diff.afterRanges {
            if let lit = Range(range, in: text) { text[lit].backgroundColor = .white.opacity(0.28) }
        }
        return text
    }
}

/// A voice, then the words it left.
private struct DictateDemo: View {
    let spoken: Bool
    let moving: Bool
    private static let bars = 22

    var body: some View {
        HStack(spacing: 14) {
            TimelineView(.animation(paused: !moving || spoken)) { timeline in
                Canvas { context, size in
                    let time = timeline.date.timeIntervalSinceReferenceDate
                    for index in 0..<Self.bars {
                        let height = spoken ? 3 : max(3, Self.level(index, at: time) * size.height)
                        let bar = CGRect(x: Double(index) * size.width / Double(Self.bars), y: (size.height - height) / 2, width: 3, height: height)
                        context.fill(Path(roundedRect: bar, cornerRadius: 1.5), with: .color(.white))
                    }
                }
            }
            .frame(width: 120, height: 30)
            // Hello's draft again, as speech would have left it.
            if spoken { Text("on my way").font(.system(size: 15, weight: .medium)).transition(.opacity) }
        }
    }

    /// Three sines under an arch: enough to read as a voice at this size.
    private static func level(_ index: Int, at time: Double) -> Double {
        let x = Double(index)
        let wave = sin(time * 7.5 + x * 0.7) * 0.5 + sin(time * 13 + x * 1.9) * 0.3 + sin(time * 4.6 - x * 0.33) * 0.2
        return sin(.pi * (x + 0.5) / Double(bars)) * (0.5 + 0.5 * wave)
    }
}
